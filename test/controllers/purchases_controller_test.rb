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
      "La IA no devolvió datos mínimos de una boleta."
    )

    assert_equal(
      "No pudimos identificar una boleta, factura o comprobante de compra. Intenta nuevamente con un archivo válido.",
      message
    )
  end
end
