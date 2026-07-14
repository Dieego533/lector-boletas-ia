require "base64"

class PurchasesController < ApplicationController
  before_action :set_purchase, only: %i[show saved edit update destroy]

  PURCHASES_PER_PAGE = 10

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

  def preview
    uploaded_receipt = params[:receipt]

    unless uploaded_receipt.present?
      @purchase = Purchase.new
      @processing_error = "Debes subir una boleta para procesarla."
      render :new, status: :unprocessable_entity
      return
    end

    result = ReceiptProcessor.new(uploaded_receipt, engine: ai_engine_param).call

    unless result.success?
      @purchase = Purchase.new
      @processing_error = result.processing_error
      render :new, status: :unprocessable_entity
      return
    end

    @purchase = Purchase.new(result.attributes)
    @raw_text = result.raw_text
    @ai_response = result.ai_response
    @processing_error = result.processing_error
    @preview_file = preview_file(uploaded_receipt)

    render :preview
  end

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
      @raw_text = @purchase.raw_text
      @ai_response = @purchase.ai_response
      @processing_error = @purchase.processing_error
      render :preview, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @purchase.update(purchase_params)
      redirect_to @purchase, notice: "Compra guardada correctamente."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @purchase.destroy!

    redirect_to purchases_path, notice: "Compra eliminada correctamente."
  end

  private

  def set_purchase
    @purchase = Purchase.find(params[:id])
  end

  def purchase_params
    params.require(:purchase).permit(
      :merchant_name,
      :merchant_rut,
      :document_number,
      :purchase_date,
      :total_amount,
      :currency,
      :raw_text,
      :processing_error
    )
  end

  def ai_engine_param
    params[:ai_engine]
  end

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
