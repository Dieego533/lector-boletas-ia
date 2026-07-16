require "test_helper"

class PurchasesControllerTest < ActionDispatch::IntegrationTest
  test "not receipt processing error is user friendly" do
    message = PurchasesController.new.send(
      :processing_error_message,
      :not_receipt,
      "El documento parece corresponder a una liquidación o reembolso de seguro."
    )

    assert_equal(
      "No pudimos identificar una boleta, factura o comprobante de compra. El documento parece corresponder a una liquidación o reembolso de seguro. Intenta nuevamente con un archivo válido.",
      message
    )
  end

  test "technical not receipt detail is hidden" do
    message = PurchasesController.new.send(
      :processing_error_message,
      :not_receipt,
      "OCR.space no detecto señales suficientes de boleta."
    )

    assert_equal(
      "No pudimos identificar una boleta, factura o comprobante de compra. Intenta nuevamente con un archivo válido.",
      message
    )
  end

  test "ocr failed message does not expose provider details" do
    message = PurchasesController.new.send(:processing_error_message, :ocr_failed)

    assert_equal(
      "No pudimos leer correctamente el archivo. Intenta nuevamente con una imagen más clara o selecciona otro método.",
      message
    )
    assert_not_includes message, "OCR"
  end
end
