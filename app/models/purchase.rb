class Purchase < ApplicationRecord
  has_many :purchase_items, -> { order(:position, :id) }, dependent: :destroy

  accepts_nested_attributes_for :purchase_items, allow_destroy: true, reject_if: :reject_purchase_item?

  scope :recent, -> { order(created_at: :desc) }
  scope :search_by_merchant, lambda { |query|
    next if query.blank?

    where("merchant_name ILIKE ? OR merchant_rut ILIKE ?", "%#{sanitize_sql_like(query)}%", "%#{sanitize_sql_like(query)}%")
  }

  def ai_model
    ai_response&.dig("model")
  end

  def ai_engine_label
    engine_label(ai_response&.dig("engine"))
  end

  def resolved_ai_engine_label
    engine_label(ai_response&.dig("resolved_engine"))
  end

  def ai_data
    ai_response&.dig("data") || ai_response
  end

  def engine_label(engine)
    {
      "auto" => "Automático",
      "vision" => "Análisis inteligente",
      "ocr_text" => "Extracción de datos"
    }[engine]
  end

  private

  def reject_purchase_item?(attributes)
    ActiveModel::Type::Boolean.new.cast(attributes["_destroy"]) || attributes["description"].blank?
  end

end
