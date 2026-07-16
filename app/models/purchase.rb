class Purchase < ApplicationRecord
  ITEM_TOTAL_WARNING_TOLERANCE = 100.to_d

  has_many :purchase_items, -> { order(:position, :id) }, dependent: :destroy

  accepts_nested_attributes_for :purchase_items, allow_destroy: true, reject_if: :reject_purchase_item?

  validates :document_number, presence: { message: "es obligatorio" }
  validates :purchase_date, presence: { message: "es obligatoria" }
  validates :total_amount, presence: { message: "es obligatorio" }, numericality: { greater_than: 0, allow_nil: true }
  validates :tax_amount, numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validate :merchant_identifier_must_be_present
  validate :tax_amount_cannot_exceed_total

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

  def items_total_amount
    purchase_items.reject(&:marked_for_destruction?).filter_map(&:total_price).sum(0.to_d)
  end

  def items_total_difference
    return 0.to_d if total_amount.blank? || items_total_amount.zero?

    total_amount - items_total_amount
  end

  def items_total_mismatch?
    return false if total_amount.blank? || items_total_amount.zero?
    return false if items_total_difference_explained_by_tax?

    items_total_difference.abs > ITEM_TOTAL_WARNING_TOLERANCE
  end

  private

  def reject_purchase_item?(attributes)
    ActiveModel::Type::Boolean.new.cast(attributes["_destroy"]) || attributes["description"].blank?
  end

  def merchant_identifier_must_be_present
    return if merchant_name.present? || merchant_rut.present?

    errors.add(:merchant_name, "o RUT comercio es obligatorio")
    errors.add(:merchant_rut, "o nombre del comercio es obligatorio")
  end

  def tax_amount_cannot_exceed_total
    return if tax_amount.blank? || total_amount.blank?
    return if tax_amount <= total_amount

    errors.add(:tax_amount, "no puede ser mayor que el total")
  end

  def items_total_difference_explained_by_tax?
    return false if tax_amount.blank?

    (items_total_difference.abs - tax_amount).abs <= ITEM_TOTAL_WARNING_TOLERANCE
  end
end
