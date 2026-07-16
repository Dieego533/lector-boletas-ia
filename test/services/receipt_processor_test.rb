require "test_helper"

class ReceiptProcessorTest < ActiveSupport::TestCase
  test "rejects documents classified as non purchase receipts" do
    error = assert_raises(ReceiptProcessor::ProcessingError) do
      processor.send(:validate_receipt_data!, {
        "document_type" => "insurance_reimbursement",
        "is_purchase_receipt" => false,
        "rejection_reason" => "El documento corresponde a un reembolso de seguro.",
        "items" => []
      })
    end

    assert_equal :not_receipt, error.code
    assert_includes error.message, "reembolso de seguro"
    assert_not_includes error.message, "insurance_reimbursement"
  end

  test "accepts minimum extracted data for purchase receipts" do
    assert_nothing_raised do
      processor.send(:validate_receipt_data!, {
        "document_type" => "receipt",
        "is_purchase_receipt" => true,
        "merchant_rut" => "12.345.678-5",
        "document_number" => "123456",
        "purchase_date" => "2026-07-15",
        "total_amount" => 12_990,
        "items" => []
      })
    end
  end

  test "accepts payment vouchers with minimum extracted data" do
    assert_nothing_raised do
      processor.send(:validate_receipt_data!, {
        "document_type" => "bank_receipt",
        "is_purchase_receipt" => false,
        "document_number" => "ABC123",
        "purchase_date" => "2026-07-15",
        "total_amount" => 12_990,
        "items" => []
      })
    end
  end

  test "normalizes unsupported document types to unknown" do
    data = processor.send(:normalize_extracted_data, { "document_type" => "voucher_transbank" })

    assert_equal "unknown", data["document_type"]
  end

  test "keeps allowed document types" do
    data = processor.send(:normalize_extracted_data, { "document_type" => "bank_transfer" })

    assert_equal "bank_transfer", data["document_type"]
  end

  private

  def processor
    ReceiptProcessor.new(nil)
  end
end
