# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_14_001000) do
  create_schema "extensions"

  # These are extensions that must be enabled in order to support this database
  enable_extension "extensions.pg_stat_statements"
  enable_extension "extensions.pgcrypto"
  enable_extension "extensions.uuid-ossp"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "vault.supabase_vault"

  create_table "public.purchase_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "description", null: false
    t.decimal "discount_amount", precision: 12, scale: 2, default: "0.0", null: false
    t.string "line_type", default: "product", null: false
    t.integer "position", default: 0, null: false
    t.bigint "purchase_id", null: false
    t.decimal "quantity", precision: 10, scale: 2, default: "1.0", null: false
    t.decimal "total_price", precision: 12, scale: 2
    t.decimal "unit_price", precision: 12, scale: 2
    t.datetime "updated_at", null: false
    t.index ["purchase_id"], name: "index_purchase_items_on_purchase_id"
  end

  create_table "public.purchases", force: :cascade do |t|
    t.jsonb "ai_response"
    t.datetime "created_at", null: false
    t.string "currency", default: "CLP", null: false
    t.string "document_number"
    t.string "merchant_name"
    t.string "merchant_rut"
    t.text "processing_error"
    t.date "purchase_date"
    t.text "raw_text"
    t.decimal "tax_amount", precision: 12, scale: 2
    t.decimal "total_amount", precision: 12, scale: 2
    t.datetime "updated_at", null: false
  end

  add_foreign_key "public.purchase_items", "public.purchases"

end
