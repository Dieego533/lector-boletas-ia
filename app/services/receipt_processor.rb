require "base64"
require "json"
require "net/http"
require "stringio"
require "uri"

class ReceiptProcessor
  Result = Struct.new(:success?, :attributes, :raw_text, :ai_response, :processing_error, keyword_init: true)

  GEMINI_MODEL = "gemini-3.1-flash-lite".freeze
  GROQ_TEXT_MODEL = "llama-3.1-8b-instant".freeze

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
      processing_error: nil
    )
  rescue StandardError => error
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
      processing_error: error.message
    )
  end

  private

  attr_reader :uploaded_file
  attr_reader :engine
  attr_reader :raw_text

  def validate_uploaded_file!
    raise "Debes subir una boleta para procesarla." if uploaded_file.blank?
    raise "El archivo debe ser PDF, JPG o PNG." unless content_type.in?(%w[application/pdf image/jpeg image/png])
    raise "El archivo debe pesar máximo 10 MB." if uploaded_file.size > 10.megabytes
  end

  def engine_config
    ENGINES.fetch(engine) { raise "Motor IA no permitido: #{engine}" }
  end

  def resolved_engine
    return engine unless engine == "auto"

    uploaded_file.size <= 1.megabyte ? "ocr_text" : "vision"
  end

  def resolved_engine_config
    ENGINES.fetch(resolved_engine)
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
    case provider
    when "gemini"
      request_gemini
    when "ocr_groq"
      request_ocr_groq
    else
      raise "Proveedor IA no soportado: #{provider}"
    end
  end

  def request_gemini
    uri = URI(format(GEMINI_ENDPOINT, model: model))
    uri.query = URI.encode_www_form(key: ENV.fetch("GEMINI_API_KEY"))

    response = post_json(uri, gemini_payload)
    raise "Gemini respondió HTTP #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def request_ocr_groq
    @raw_text = extract_text_with_ocr_space
    raise "OCR.space no detecto texto suficiente. Prueba Análisis inteligente." if raw_text.blank? || raw_text.length < 20

    uri = URI(GROQ_ENDPOINT)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{ENV.fetch('GROQ_API_KEY')}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(groq_text_payload(raw_text))

    response = perform_request(uri, request)
    raise "Groq respondió HTTP #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
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
    raise "OCR.space respondió HTTP #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    body = JSON.parse(response.body)
    raise "OCR.space error: #{body['ErrorMessage'] || body['ErrorDetails']}" if body["IsErroredOnProcessing"]

    Array(body["ParsedResults"]).filter_map { |result| result["ParsedText"] }.join("\n").strip
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
      merchant_name, merchant_rut, document_number, purchase_date, total_amount, currency.

      Reglas:
      - Si un dato no esta disponible, usa null.
      - No inventes informacion.
      - purchase_date debe venir en formato YYYY-MM-DD.
      - total_amount debe ser un numero, sin puntos de miles ni simbolos.
      - currency debe ser CLP salvo que la boleta indique otra moneda.
      - No agregues claves adicionales.
    PROMPT
  end

  def parse_response(response)
    text = if provider == "gemini"
      response.dig("candidates", 0, "content", "parts", 0, "text")
    else
      response.dig("choices", 0, "message", "content")
    end

    raise "#{provider_name} no devolvio texto procesable" if text.blank?

    JSON.parse(clean_json_text(text))
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
      currency: data["currency"].presence || "CLP"
    }.compact
  end

  def provider_name
    return "Gemini" if provider == "gemini"
    return "OCR.space + Groq" if provider == "ocr_groq"

    "IA"
  end
end
