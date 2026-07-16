require "test_helper"

class PurchaseTest < ActiveSupport::TestCase
  test "requires minimum receipt fields" do
    purchase = Purchase.new

    assert_not purchase.valid?
    assert_includes purchase.errors[:merchant_name], "o RUT comercio es obligatorio"
    assert_includes purchase.errors[:merchant_rut], "o nombre del comercio es obligatorio"
    assert_includes purchase.errors[:document_number], "es obligatorio"
    assert_includes purchase.errors[:purchase_date], "es obligatoria"
    assert_includes purchase.errors[:total_amount], "es obligatorio"
  end

  test "requires positive total amount" do
    purchase = Purchase.new(valid_purchase_attributes(total_amount: 0))

    assert_not purchase.valid?
    assert_includes purchase.errors[:total_amount], "must be greater than 0"
  end

  test "accepts any merchant rut format for demo" do
    purchase = Purchase.new(valid_purchase_attributes(merchant_rut: "12.345.678-9"))

    assert purchase.valid?
  end

  test "rejects tax amount greater than total" do
    purchase = Purchase.new(valid_purchase_attributes(total_amount: 1_000, tax_amount: 1_001))

    assert_not purchase.valid?
    assert_includes purchase.errors[:tax_amount], "no puede ser mayor que el total"
  end

  test "accepts minimum valid receipt fields" do
    purchase = Purchase.new(valid_purchase_attributes)

    assert purchase.valid?
  end

  test "accepts merchant name without merchant rut" do
    purchase = Purchase.new(valid_purchase_attributes(merchant_rut: nil, merchant_name: "MEGASALUD"))

    assert purchase.valid?
  end

  test "accepts merchant rut without merchant name" do
    purchase = Purchase.new(valid_purchase_attributes(merchant_name: nil))

    assert purchase.valid?
  end

  test "does not warn when items total difference is within tolerance" do
    purchase = Purchase.new(valid_purchase_attributes(total_amount: 1_000))
    purchase.purchase_items.build(description: "Producto", total_price: 900)

    assert_equal 900.to_d, purchase.items_total_amount
    assert_equal 100.to_d, purchase.items_total_difference
    assert_not purchase.items_total_mismatch?
  end

  test "warns when items total difference exceeds tolerance" do
    purchase = Purchase.new(valid_purchase_attributes(total_amount: 1_000))
    purchase.purchase_items.build(description: "Producto", total_price: 899)

    assert_equal 899.to_d, purchase.items_total_amount
    assert_equal 101.to_d, purchase.items_total_difference
    assert purchase.items_total_mismatch?
  end

  test "does not warn when items difference is explained by tax breakdown" do
    purchase = Purchase.new(valid_purchase_attributes(total_amount: 1_550, tax_amount: 247))
    purchase.purchase_items.build(description: "Compra", total_price: 1_303)

    assert_equal 1_303.to_d, purchase.items_total_amount
    assert_equal 247.to_d, purchase.items_total_difference
    assert_not purchase.items_total_mismatch?
  end

  private

  def valid_purchase_attributes(overrides = {})
    {
      merchant_rut: "12.345.678-5",
      merchant_name: "Comercio de prueba",
      document_number: "123456",
      purchase_date: Date.new(2026, 7, 15),
      total_amount: 12_990,
      tax_amount: 2_074,
      currency: "CLP"
    }.merge(overrides)
  end
end
