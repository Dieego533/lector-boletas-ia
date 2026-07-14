class CreatePurchaseItems < ActiveRecord::Migration[8.1]
  def change
    create_table :purchase_items do |t|
      t.references :purchase, null: false, foreign_key: true
      t.string :line_type, default: "product", null: false
      t.string :description, null: false
      t.decimal :quantity, precision: 10, scale: 2, default: 1, null: false
      t.decimal :unit_price, precision: 12, scale: 2
      t.decimal :discount_amount, precision: 12, scale: 2, default: 0, null: false
      t.decimal :total_price, precision: 12, scale: 2
      t.integer :position, default: 0, null: false

      t.timestamps
    end
  end
end
