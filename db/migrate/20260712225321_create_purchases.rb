class CreatePurchases < ActiveRecord::Migration[8.1]
  def change
    create_table :purchases do |t|
      t.string :merchant_name
      t.string :merchant_rut
      t.string :document_number
      t.date :purchase_date
      t.decimal :total_amount, precision: 12, scale: 2
      t.string :currency, default: "CLP", null: false
      t.text :raw_text
      t.jsonb :ai_response
      t.text :processing_error

      t.timestamps
    end
  end
end
