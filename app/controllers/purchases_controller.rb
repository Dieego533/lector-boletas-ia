require "base64"

class PurchasesController < ApplicationController
  #buscamos el id en la base de datos antes de cualquiera de las acciones que lo requieran
  before_action :set_purchase, only: %i[show saved edit update destroy]

  PURCHASES_PER_PAGE = 10

  # Muestra el listado principal de compras.
  def index
    @page = [params[:page].to_i, 1].max
    purchases = Purchase.recent.search_by_merchant(params[:query])
    @total_purchases = purchases.count
    @total_pages = (@total_purchases.to_f / PURCHASES_PER_PAGE).ceil
    @page = @total_pages if @total_pages.positive? && @page > @total_pages
    @purchases = purchases.offset((@page - 1) * PURCHASES_PER_PAGE).limit(PURCHASES_PER_PAGE)
  end

  def show
  end

  def saved
  end

  def new
    @purchase = Purchase.new
  end

  # Procesa el archivo, pero todavía no guarda nada.
  def preview
    uploaded_receipt = params[:receipt].presence || params[:receipt_camera]

    unless uploaded_receipt.present?
      @purchase = Purchase.new
      @processing_error = "Debes subir una boleta para procesarla."
      render :new, status: :unprocessable_entity
      return
    end

    # Se extraen los datos con IA/OCR
    result = ReceiptProcessor.new(uploaded_receipt, engine: ai_engine_param).call

    unless result.success?
      @purchase = Purchase.new
      @processing_error = processing_error_message(result.error_code, result.processing_error)
      render :new, status: :unprocessable_entity
      return
    end

    @purchase = Purchase.new(purchase_attributes_for_model(result.attributes))
    @raw_text = result.raw_text
    @ai_response = result.ai_response
    @processing_error = result.processing_error
    @preview_file = preview_file(uploaded_receipt)

    render :preview
  end

  # Guarda la compra después de que el usuario revisa el formulario.
  def create
    @purchase = Purchase.new(purchase_params)
    @purchase.ai_response = JSON.parse(params.dig(:purchase, :ai_response).presence || "{}")

    if @purchase.save
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.update(
            "success_modal_root",
            partial: "purchases/saved_modal"
          )
        end
        format.html { redirect_to saved_purchase_path(@purchase) }
      end
    else
      log_save_error(@purchase)
      @raw_text = @purchase.raw_text
      @ai_response = @purchase.ai_response
      @processing_error = save_error_message
      render :preview, status: :unprocessable_entity
    end
  end

  def edit
    @return_to = safe_return_path(params[:return_to]) || purchase_path(@purchase)
  end

  # Guarda cambios sobre una compra existente.
  def update
    if @purchase.update(purchase_params)
      redirect_to safe_return_path(params[:return_to]) || @purchase, notice: "Compra guardada correctamente."
    else
      log_save_error(@purchase)
      @return_to = safe_return_path(params[:return_to]) || purchase_path(@purchase)
      render :edit, status: :unprocessable_entity
    end
  end

  # Elimina la compra y sus productos asociados.
  def destroy
    @purchase.destroy!

    redirect_to purchases_path, notice: "Compra eliminada correctamente."
  end

  private

  def set_purchase
    @purchase = Purchase.find(params[:id])
  end

  # Define qué datos del formulario se pueden guardar.
  def purchase_params
    attributes = params.require(:purchase).permit(
      :merchant_name,
      :merchant_rut,
      :document_number,
      :purchase_date,
      :total_amount,
      :tax_amount,
      :raw_text,
      :processing_error,
      purchase_items_attributes: %i[id line_type description quantity unit_price discount_amount total_price position _destroy]
    ).merge(currency: "CLP")

    purchase_attributes_for_model(attributes)
  end

  def purchase_attributes_for_model(attributes)
    attributes = attributes.to_h
    attributes.except!("tax_amount", :tax_amount) unless Purchase.column_names.include?("tax_amount")
    attributes
  end

  def ai_engine_param
    params[:ai_engine]
  end

  # Traduce errores técnicos a mensajes entendibles para el usuario.
  def processing_error_message(error_code, detail = nil)
    if error_code&.to_sym == :not_receipt && detail.present?
      detail = user_facing_not_receipt_detail(detail)
      message = "No pudimos identificar una boleta, factura o comprobante de compra."
      message = "#{message} #{detail}" if detail.present?
      return "#{message} Intenta nuevamente con un archivo válido."
    end

    {
      missing_file: "Debes subir una boleta para continuar.",
      unsupported_file_type: "El archivo debe ser PDF, JPG o PNG.",
      file_too_large: "El archivo no puede superar los 10 MB.",
      ocr_failed: "No pudimos leer correctamente el archivo. Intenta nuevamente con una imagen más clara o selecciona otro método.",
      ai_provider_failed: "No pudimos procesar el archivo. Intenta nuevamente con otro método.",
      rate_limited: "El servicio de IA alcanzó un límite de uso. Intenta nuevamente más tarde o selecciona otro método de procesamiento.",
      invalid_ai_response: "No pudimos estructurar la información del documento. Intenta nuevamente con otro método.",
      not_receipt: "No pudimos identificar una boleta en el archivo. Intenta con otra imagen o selecciona otro método.",
      prompt_unavailable: "Ocurrió un problema al procesar la boleta. Intenta nuevamente.",
      unsupported_engine: "El método de procesamiento seleccionado no está disponible."
    }.fetch(error_code&.to_sym, "Ocurrió un problema al procesar la boleta. Intenta nuevamente.")
  end

  def save_error_message
    "No se pudo guardar la compra. Revisa los campos e intenta nuevamente."
  end

  def user_facing_not_receipt_detail(detail)
    technical_terms = /\b(?:IA|OCR|OCR\.space|Gemini|Groq|HTTP|JSON|proveedor|provider|modelo|model)\b|datos mínimos|texto suficiente|señales suficientes/i
    return "" if detail.match?(technical_terms)

    detail.squish
  end

  def log_save_error(purchase)
    Rails.logger.error(
      "[PurchasesController] save_failed " \
      "purchase_errors=#{purchase.errors.full_messages.inspect} " \
      "params_keys=#{params.to_unsafe_h.keys.inspect}"
    )
  end

  def safe_return_path(path)
    return if path.blank?

    uri = URI.parse(path)
    return unless uri.host.blank? && uri.scheme.blank? && uri.path.start_with?("/")

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  # Prepara una vista previa pequeña de la boleta original.
  def preview_file(uploaded_receipt)
    return unless uploaded_receipt.content_type.in?(%w[image/jpeg image/png application/pdf])
    return if uploaded_receipt.size > 3.megabytes

    uploaded_receipt.rewind if uploaded_receipt.respond_to?(:rewind)
    data = Base64.strict_encode64(uploaded_receipt.read)
    uploaded_receipt.rewind if uploaded_receipt.respond_to?(:rewind)

    {
      data_url: "data:#{uploaded_receipt.content_type};base64,#{data}",
      filename: uploaded_receipt.original_filename,
      content_type: uploaded_receipt.content_type
    }
  end
end
