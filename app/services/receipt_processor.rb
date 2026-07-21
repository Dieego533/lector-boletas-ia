require "base64"
require "bigdecimal"
require "json"
require "net/http"
require "stringio"
require "uri"

class ReceiptProcessor
  class ProcessingError < StandardError
    attr_reader :code

    # Guarda un código simple para identificar el tipo de error.
    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  Result = Struct.new(:success?, :attributes, :raw_text, :ai_response, :processing_error, :error_code, keyword_init: true)


  GEMINI_MODEL = "gemini-3.1-flash-lite".freeze
  GROQ_TEXT_MODEL = "llama-3.1-8b-instant".freeze
  OCR_AUTO_MAX_SIZE = 1.5.megabytes


  ENGINES = {
    "auto" => {
      label: "Automático (Recomendado)",
      provider: "auto",
      model: nil
    },
    "vision" => {
      label: "Análisis inteligente",
      provider: "gemini",
      model: GEMINI_MODEL
    },
    "ocr_text" => {
      label: "Extracción de datos",
      provider: "ocr_groq",
      model: GROQ_TEXT_MODEL
    }
  }.freeze

  # Tipos de documento que la IA puede devolver en su clasificación.
  DOCUMENT_TYPES = %w[
    receipt invoice ticket payment_voucher card_receipt bank_receipt bank_transfer bank_deposit
    insurance_reimbursement quote medical_order account_statement certificate benefits_document unknown
  ].freeze

  # Vouchers que se aceptan aunque no son boletas como tal.
  PURCHASE_SUPPORT_DOCUMENT_TYPES = %w[payment_voucher card_receipt bank_receipt].freeze

  GEMINI_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/%<model>s:generateContent".freeze
  GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions".freeze
  OCR_SPACE_ENDPOINT = "https://api.ocr.space/parse/image".freeze

  PROMPT_PATH = Rails.root.join("config/prompts/receipt_extraction.txt").freeze

  def self.engine_options
    ENGINES.map { |value, config| [config[:label], value] }
  end

  def self.default_engine
    ENV.fetch("AI_ENGINE", "auto")
  end

  def initialize(uploaded_file, engine: nil)
    @uploaded_file = uploaded_file
    @engine = engine.presence || self.class.default_engine
  end

  # Flujo principal: valida el archivo, procesa con IA/OCR y devuelve datos para el formulario.
  def call
    validate_uploaded_file!

    response = request_ai
    extracted_data = parse_response(response)
    validate_receipt_data!(extracted_data)
    attributes = attributes_from(extracted_data)

    Result.new(
      success?: true,
      attributes: attributes,
      raw_text: raw_text,
      ai_response: {
        "engine" => engine,
        "resolved_engine" => resolved_engine,
        "provider" => provider,
        "model" => model,
        "data" => extracted_data
      },
      processing_error: nil,
      error_code: nil
    )
  rescue StandardError => error
    log_processing_error(error)

    Result.new(
      success?: false,
      attributes: {},
      raw_text: raw_text,
      ai_response: {
        "engine" => engine,
        "resolved_engine" => resolved_engine_safe,
        "provider" => provider_safe,
        "model" => model_safe,
        "data" => {}
      },
      processing_error: error.message,
      error_code: error_code_for(error)
    )
  end

  private

  attr_reader :uploaded_file
  attr_reader :engine
  attr_reader :raw_text

  def validate_uploaded_file!
    raise ProcessingError.new(:missing_file, "Debes subir una boleta para procesarla.") if uploaded_file.blank?
    raise ProcessingError.new(:unsupported_file_type, "El archivo debe ser PDF, JPG o PNG.") unless content_type.in?(%w[application/pdf image/jpeg image/png])
    raise ProcessingError.new(:file_too_large, "El archivo debe pesar máximo 10 MB.") if uploaded_file.size > 10.megabytes
  end

  # Busca la configuración del método elegido.
  def engine_config
    ENGINES.fetch(engine) { raise ProcessingError.new(:unsupported_engine, "Motor IA no permitido: #{engine}") }
  end

  # Devuelve el método finalmente usado cuando el modo es automático.
  def resolved_engine
    return @resolved_engine if defined?(@resolved_engine)
    return engine unless engine == "auto"

    nil
  end

  def resolved_engine_config
    ENGINES.fetch(resolved_engine) { raise ProcessingError.new(:unsupported_engine, "Motor IA no permitido: #{resolved_engine}") }
  end

  def provider
    resolved_engine_config[:provider]
  end

  def model
    resolved_engine_config[:model]
  end

  def resolved_engine_safe
    resolved_engine
  rescue StandardError
    nil
  end

  def provider_safe
    provider
  rescue StandardError
    nil
  end

  def model_safe
    model
  rescue StandardError
    nil
  end

  # Ejecuta el método elegido: automático, visión o OCR + texto.
  def request_ai
    return request_auto if engine == "auto"

    # Si el usuario eligió un método manual, se respeta esa opción.
    case provider
    when "gemini"
      request_gemini
    when "ocr_groq"
      request_ocr_groq
    else
      raise ProcessingError.new(:unsupported_engine, "Proveedor IA no soportado: #{provider}")
    end
  end

  # Decide automáticamente si conviene usar OCR + texto o análisis visual.
  def request_auto
    if uploaded_file.size > OCR_AUTO_MAX_SIZE
      @resolved_engine = "vision"
      return request_gemini
    end

    # Primero intenta leer texto para usar el método más liviano.
    @raw_text = extract_text_with_ocr_space
    raise ProcessingError.new(:ocr_failed, "OCR.space no detecto texto suficiente.") if raw_text.blank? || raw_text.length < 20

    @resolved_engine = complex_receipt_text?(raw_text) ? "vision" : "ocr_text"

    if resolved_engine == "vision"
      request_gemini
    else
      request_groq_with_text(raw_text)
    end
  end

  def request_gemini
    uri = URI(format(GEMINI_ENDPOINT, model: model))
    uri.query = URI.encode_www_form(key: ENV.fetch("GEMINI_API_KEY"))

    # Llamada a Gemini para analizar directamente la imagen o PDF.
    response = post_json(uri, gemini_payload)
    raise_ai_provider_error("Gemini", response) unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => error
    raise ProcessingError.new(:ai_provider_failed, "Gemini devolvió JSON inválido: #{error.message}")
  end

  # Extrae texto con OCR y luego lo estructura con el modelo liviano.
  def request_ocr_groq
    @raw_text ||= extract_text_with_ocr_space
    raise ProcessingError.new(:ocr_failed, "OCR.space no detecto texto suficiente.") if raw_text.blank? || raw_text.length < 20

    request_groq_with_text(raw_text)
  end

  def request_groq_with_text(text)
    uri = URI(GROQ_ENDPOINT)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{ENV.fetch('GROQ_API_KEY')}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(groq_text_payload(text))

    # Llamada a Groq para transformar el texto OCR en datos estructurados.
    response = perform_request(uri, request)
    raise_ai_provider_error("Groq", response) unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => error
    raise ProcessingError.new(:ai_provider_failed, "Groq devolvió JSON inválido: #{error.message}")
  end

  # Detecta si el texto parece complejo y conviene usar análisis visual.
  def complex_receipt_text?(text)
    normalized_text = I18n.transliterate(text.to_s).downcase
    lines = normalized_text.lines.map(&:strip).reject(&:blank?)

    table_terms = [
      "descto", "dscto", "dcto", "descuento",
      "p. unitario", "p unitario", "precio unitario",
      "cantidad", "detalle"
    ]
    summary_terms = ["total descto", "total dscto", "monto neto", "monto iva", "monto total", "subtotal"]

    return true if table_terms.count { |term| normalized_text.include?(term) } >= 2
    return true if summary_terms.any? { |term| normalized_text.include?(term) }

    numeric_heavy_lines = lines.count { |line| line.scan(/\d[\d.,-]*/).size >= 3 }
    long_code_lines = lines.count { |line| line.match?(/\b\d{8,}\b/) }

    numeric_heavy_lines >= 2 || long_code_lines >= 2
  end

  # Extrae texto del archivo usando OCR.space.
  def extract_text_with_ocr_space
    uri = URI(OCR_SPACE_ENDPOINT)
    request = Net::HTTP::Post.new(uri)
    request["apikey"] = ENV.fetch("OCR_SPACE_API_KEY")
    request.set_form(
      [
        ["file", StringIO.new(file_data), { filename: uploaded_file.original_filename.to_s, content_type: content_type }],
        ["language", "spa"],
        ["OCREngine", "3"],
        ["scale", "true"],
        ["detectOrientation", "true"],
        ["isOverlayRequired", "false"]
      ],
      "multipart/form-data"
    )

    # Llamada al servicio OCR para obtener texto desde el archivo.
    response = perform_request(uri, request)
    raise ProcessingError.new(:ocr_failed, "OCR.space respondió HTTP #{response.code}: #{response.body}") unless response.is_a?(Net::HTTPSuccess)

    body = JSON.parse(response.body)
    raise ProcessingError.new(:ocr_failed, "OCR.space error: #{body['ErrorMessage'] || body['ErrorDetails']}") if body["IsErroredOnProcessing"]

    Array(body["ParsedResults"]).filter_map { |result| result["ParsedText"] }.join("\n").strip
  rescue JSON::ParserError => error
    raise ProcessingError.new(:ocr_failed, "OCR.space devolvió JSON inválido: #{error.message}")
  end

  # Envía un request JSON a un servicio externo.
  def post_json(uri, payload)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(payload)

    perform_request(uri, request)
  end

  # Ejecuta la llamada HTTP con SSL y timeout.
  def perform_request(uri, request)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 60
    http.request(request)
  end

  # Convierte errores HTTP del proveedor en errores internos de la app.
  def raise_ai_provider_error(provider_label, response)
    message = "#{provider_label} respondió HTTP #{response.code}: #{response.body}"
    error_code = response.code.to_i == 429 ? :rate_limited : :ai_provider_failed

    raise ProcessingError.new(error_code, message)
  end

  # Arma el cuerpo que se envía a Gemini junto con el archivo.
  def gemini_payload
    {
      contents: [
        {
          role: "user",
          parts: [
            { text: prompt },
            {
              inline_data: {
                mime_type: content_type,
                data: encoded_file
              }
            }
          ]
        }
      ],
      generationConfig: {
        temperature: 0.1,
        response_mime_type: "application/json"
      }
    }
  end

  # Arma el cuerpo que se envía a Groq con el texto extraído por OCR.
  def groq_text_payload(text)
    {
      model: model,
      messages: [
        {
          role: "user",
          content: "#{prompt}\n\nTexto extraido por OCR:\n#{text}"
        }
      ],
      temperature: 0.1,
      response_format: { type: "json_object" }
    }
  end

  def prompt
    # Instrucciones que guían a la IA para clasificar y extraer datos.
    File.read(PROMPT_PATH)
  rescue Errno::ENOENT => error
    raise ProcessingError.new(:prompt_unavailable, "No se encontró el archivo de instrucciones: #{error.message}")
  end

  # Convierte la respuesta del proveedor en datos JSON utilizables.
  def parse_response(response)
    text = if provider == "gemini"
      response.dig("candidates", 0, "content", "parts", 0, "text")
    else
      response.dig("choices", 0, "message", "content")
    end

    raise ProcessingError.new(:invalid_ai_response, "#{provider_name} no devolvio texto procesable") if text.blank?

    normalize_extracted_data(JSON.parse(clean_json_text(text)))
  rescue JSON::ParserError => error
    raise ProcessingError.new(:invalid_ai_response, "#{provider_name} devolvió JSON inválido: #{error.message}")
  end

  # Normaliza datos devueltos por la IA antes de usarlos.
  def normalize_extracted_data(data)
    return data unless data.is_a?(Hash)

    data.merge("document_type" => normalize_document_type(data["document_type"]))
  end

  # Asegura que el tipo de documento sea uno de los permitidos.
  def normalize_document_type(document_type)
    normalized_type = document_type.to_s.parameterize(separator: "_")
    return normalized_type if DOCUMENT_TYPES.include?(normalized_type)

    "unknown"
  end

  # Limpia bloques markdown si el proveedor envolvió el JSON en ```.
  def clean_json_text(text)
    text.strip.gsub(/\A```(?:json)?\s*/i, "").gsub(/\s*```\z/, "")
  end

  # Lee el archivo subido y lo deja disponible para reutilizarlo.
  def file_data
    @file_data ||= begin
      uploaded_file.rewind if uploaded_file.respond_to?(:rewind)
      uploaded_file.read
    ensure
      uploaded_file.rewind if uploaded_file.respond_to?(:rewind)
    end
  end

  # Convierte el archivo a base64 para enviarlo a Gemini.
  def encoded_file
    @encoded_file ||= Base64.strict_encode64(file_data)
  end

  # Devuelve el tipo de archivo subido.
  def content_type
    uploaded_file.content_type
  end

  # Convierte los datos extraídos al formato del modelo Purchase.
  def attributes_from(data)
    {
      merchant_name: data["merchant_name"],
      merchant_rut: data["merchant_rut"],
      document_number: data["document_number"],
      purchase_date: data["purchase_date"],
      total_amount: data["total_amount"],
      tax_amount: data["tax_amount"],
      currency: "CLP",
      purchase_items_attributes: item_attributes_from(data["items"])
    }.compact
  end

  # Revisa que la respuesta tenga información suficiente para seguir al formulario.
  def validate_receipt_data!(data)
    validate_purchase_receipt_classification!(data)

    # Evita avanzar si la respuesta no trae datos mínimos de compra.
    total_amount = decimal_or_nil(data["total_amount"])
    tax_amount = decimal_or_nil(data["tax_amount"])
    items = Array(data["items"]).select { |item| item.is_a?(Hash) && item["description"].to_s.squish.present? }
    identity_fields = [
      data["merchant_name"],
      data["merchant_rut"],
      data["document_number"],
      data["purchase_date"]
    ].compact_blank

    return if total_amount.present? && (identity_fields.any? || tax_amount.present? || items.any?)
    return if items.any? && (total_amount.present? || tax_amount.present? || identity_fields.any?)

    raise ProcessingError.new(:not_receipt, "El archivo no contiene datos suficientes de una compra.")
  end

  # Rechaza documentos que la IA clasificó como no compra.
  def validate_purchase_receipt_classification!(data)
    return if ActiveModel::Type::Boolean.new.cast(data["is_purchase_receipt"])

    document_type = normalize_document_type(data["document_type"])
    return if PURCHASE_SUPPORT_DOCUMENT_TYPES.include?(document_type)

    rejection_reason = data["rejection_reason"].presence || "El documento no corresponde a una boleta, factura, ticket o comprobante de compra."
    raise ProcessingError.new(:not_receipt, rejection_reason)
  end

  # Convierte los productos detectados por IA al formato que espera Rails.
  def item_attributes_from(items)
    Array(items).filter_map.with_index do |item, index|
      next unless item.is_a?(Hash)

      description = item["description"].to_s.squish
      next if description.blank?

      quantity = decimal_or_default(item["quantity"], 1)
      unit_price = decimal_or_nil(item["unit_price"])
      discount_amount = decimal_or_default(item["discount_amount"], 0).abs
      total_price = decimal_or_nil(item["total_price"]) || calculated_total_price(quantity, unit_price, discount_amount)

      {
        line_type: "product",
        description: description,
        quantity: quantity,
        unit_price: unit_price,
        discount_amount: discount_amount,
        total_price: total_price,
        position: index
      }
    end
  end

  # Calcula el total de un producto cuando la IA no lo entregó.
  def calculated_total_price(quantity, unit_price, discount_amount)
    return if unit_price.blank?

    (unit_price * quantity) - discount_amount
  end

  # Devuelve un decimal o un valor por defecto.
  def decimal_or_default(value, default)
    decimal_or_nil(value) || default
  end

  # Convierte textos de montos a decimal de forma segura.
  def decimal_or_nil(value)
    return if value.blank?

    return BigDecimal(value.to_s) if value.is_a?(Numeric)

    normalized_value = value.to_s.strip.gsub(/[^\d,.-]/, "")
    normalized_value = if normalized_value.include?(",")
      normalized_value.delete(".").tr(",", ".")
    else
      normalized_value.delete(".")
    end

    BigDecimal(normalized_value)
  rescue ArgumentError
    nil
  end

  # Devuelve un nombre simple del proveedor usado.
  def provider_name
    return "Gemini" if provider == "gemini"
    return "OCR.space + Groq" if provider == "ocr_groq"

    "IA"
  end

  # Obtiene el código de error para comunicarlo al controller.
  def error_code_for(error)
    return error.code if error.respond_to?(:code)

    :unknown_error
  end

  # Guarda detalles técnicos del error en logs.
  def log_processing_error(error)
    Rails.logger.error(
      "[ReceiptProcessor] " \
      "code=#{error_code_for(error)} " \
      "error_class=#{error.class.name} " \
      "error_message=#{error.message.inspect} " \
      "engine=#{engine.inspect} " \
      "resolved_engine=#{resolved_engine_safe.inspect} " \
      "provider=#{provider_safe.inspect} " \
      "model=#{model_safe.inspect} " \
      "content_type=#{content_type_safe.inspect} " \
      "file_size=#{uploaded_file&.size.inspect} " \
      "filename=#{uploaded_file&.original_filename.to_s.inspect} " \
      "backtrace=#{Array(error.backtrace).first(5).join(' | ').inspect}"
    )
  end

  # Devuelve el tipo de archivo sin romper si no hay archivo válido.
  def content_type_safe
    content_type
  rescue StandardError
    nil
  end
end
