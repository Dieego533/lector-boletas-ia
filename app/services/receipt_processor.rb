require "base64"
require "bigdecimal"
require "json"
require "net/http"
require "stringio"
require "uri"

class ReceiptProcessor
  class ProcessingError < StandardError
    attr_reader :code

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

  GEMINI_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/%<model>s:generateContent".freeze
  GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions".freeze
  OCR_SPACE_ENDPOINT = "https://api.ocr.space/parse/image".freeze

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

  def engine_config
    ENGINES.fetch(engine) { raise ProcessingError.new(:unsupported_engine, "Motor IA no permitido: #{engine}") }
  end

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

  def request_ai
    return request_auto if engine == "auto"

    case provider
    when "gemini"
      request_gemini
    when "ocr_groq"
      request_ocr_groq
    else
      raise ProcessingError.new(:unsupported_engine, "Proveedor IA no soportado: #{provider}")
    end
  end

  def request_auto
    if uploaded_file.size > OCR_AUTO_MAX_SIZE
      @resolved_engine = "vision"
      return request_gemini
    end

    @raw_text = extract_text_with_ocr_space
    raise ProcessingError.new(:ocr_failed, "OCR.space no detecto texto suficiente.") if raw_text.blank? || raw_text.length < 20
    raise ProcessingError.new(:not_receipt, "OCR.space no detecto señales suficientes de boleta.") unless receipt_like_text?(raw_text)

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

    response = post_json(uri, gemini_payload)
    raise ProcessingError.new(:ai_provider_failed, "Gemini respondió HTTP #{response.code}: #{response.body}") unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => error
    raise ProcessingError.new(:ai_provider_failed, "Gemini devolvió JSON inválido: #{error.message}")
  end

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

    response = perform_request(uri, request)
    raise ProcessingError.new(:ai_provider_failed, "Groq respondió HTTP #{response.code}: #{response.body}") unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => error
    raise ProcessingError.new(:ai_provider_failed, "Groq devolvió JSON inválido: #{error.message}")
  end

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

  def receipt_like_text?(text)
    normalized_text = I18n.transliterate(text.to_s).downcase
    return false if normalized_text.blank?

    amount_present = normalized_text.match?(/\$\s*\d{1,3}(?:[\.,]\d{3})+/) ||
      normalized_text.match?(/\b(?:total|iva|neto|subtotal|precio|monto)\b[^\n\d]{0,20}\d{3,}/) ||
      normalized_text.match?(/\b\d{1,3}(?:[\.,]\d{3})+\b/)

    receipt_signals = %w[
      boleta factura ticket comprobante rut total iva neto subtotal vendedor caja fecha cantidad precio detalle producto comercio monto
    ]
    signal_count = receipt_signals.count { |signal| normalized_text.include?(signal) }

    amount_present && signal_count >= 2
  end

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

    response = perform_request(uri, request)
    raise ProcessingError.new(:ocr_failed, "OCR.space respondió HTTP #{response.code}: #{response.body}") unless response.is_a?(Net::HTTPSuccess)

    body = JSON.parse(response.body)
    raise ProcessingError.new(:ocr_failed, "OCR.space error: #{body['ErrorMessage'] || body['ErrorDetails']}") if body["IsErroredOnProcessing"]

    Array(body["ParsedResults"]).filter_map { |result| result["ParsedText"] }.join("\n").strip
  rescue JSON::ParserError => error
    raise ProcessingError.new(:ocr_failed, "OCR.space devolvió JSON inválido: #{error.message}")
  end

  def post_json(uri, payload)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(payload)

    perform_request(uri, request)
  end

  def perform_request(uri, request)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 60
    http.request(request)
  end

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
    <<~PROMPT
      Extrae los datos principales de esta boleta de compra chilena.

      Devuelve exclusivamente JSON valido con estas claves exactas:
      merchant_name, merchant_rut, document_number, purchase_date, total_amount, tax_amount, items.

      Reglas:
      - Si un dato no esta disponible, usa null.
      - No inventes informacion.
      - purchase_date debe venir en formato YYYY-MM-DD.
      - total_amount debe ser un numero, sin puntos de miles ni simbolos.
      - tax_amount debe ser el monto de IVA si aparece en la boleta. Si no aparece, usa null.
      - items debe ser un arreglo. Si no detectas productos, devuelve [].
      - Cada item debe tener estas claves exactas: description, quantity, unit_price, discount_amount, total_price.
      - description debe ser el nombre del producto o servicio, sin lineas de subtotal ni total.
      - quantity debe ser numerica. Si no aparece cantidad, usa 1.
      - unit_price debe ser el precio original unitario o de linea antes de descuentos, sin puntos de miles ni simbolos.
      - discount_amount debe ser el descuento aplicado al producto como numero positivo. Si no hay descuento, usa 0.
      - total_price debe ser el precio final del producto despues del descuento.
      - Si una linea "*** Descuento" aparece debajo de un producto, asociala al item anterior en discount_amount.
      - No agregues subtotales, totales, vuelto, forma de pago ni lineas de descuento como productos separados.
      - No agregues claves adicionales.
    PROMPT
  end

  def parse_response(response)
    text = if provider == "gemini"
      response.dig("candidates", 0, "content", "parts", 0, "text")
    else
      response.dig("choices", 0, "message", "content")
    end

    raise ProcessingError.new(:invalid_ai_response, "#{provider_name} no devolvio texto procesable") if text.blank?

    JSON.parse(clean_json_text(text))
  rescue JSON::ParserError => error
    raise ProcessingError.new(:invalid_ai_response, "#{provider_name} devolvió JSON inválido: #{error.message}")
  end

  def clean_json_text(text)
    text.strip.gsub(/\A```(?:json)?\s*/i, "").gsub(/\s*```\z/, "")
  end

  def file_data
    @file_data ||= begin
      uploaded_file.rewind if uploaded_file.respond_to?(:rewind)
      uploaded_file.read
    ensure
      uploaded_file.rewind if uploaded_file.respond_to?(:rewind)
    end
  end

  def encoded_file
    @encoded_file ||= Base64.strict_encode64(file_data)
  end

  def content_type
    uploaded_file.content_type
  end

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

  def validate_receipt_data!(data)
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

    raise ProcessingError.new(:not_receipt, "La IA no devolvió datos mínimos de una boleta.")
  end

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

  def calculated_total_price(quantity, unit_price, discount_amount)
    return if unit_price.blank?

    (unit_price * quantity) - discount_amount
  end

  def decimal_or_default(value, default)
    decimal_or_nil(value) || default
  end

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

  def provider_name
    return "Gemini" if provider == "gemini"
    return "OCR.space + Groq" if provider == "ocr_groq"

    "IA"
  end

  def error_code_for(error)
    return error.code if error.respond_to?(:code)

    :unknown_error
  end

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

  def content_type_safe
    content_type
  rescue StandardError
    nil
  end
end
