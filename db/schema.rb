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

ActiveRecord::Schema[8.1].define(version: 2026_07_13_001000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "purchases", force: :cascade do |t|
    t.jsonb "ai_response"
    t.datetime "created_at", null: false
    t.string "currency", default: "CLP", null: false
    t.string "document_number"
    t.string "merchant_name"
    t.string "merchant_rut"
    t.text "processing_error"
    t.date "purchase_date"
    t.text "raw_text"
    t.decimal "total_amount", precision: 12, scale: 2
    t.datetime "updated_at", null: false
  end
end
