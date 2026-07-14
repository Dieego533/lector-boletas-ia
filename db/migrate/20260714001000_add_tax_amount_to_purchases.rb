class AddTaxAmountToPurchases < ActiveRecord::Migration[8.1]
  def change
    add_column :purchases, :tax_amount, :decimal, precision: 12, scale: 2
  end
end
