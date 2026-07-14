class PurchaseItem < ApplicationRecord
  belongs_to :purchase

  LINE_TYPES = %w[product discount adjustment].freeze

  validates :description, presence: true
  validates :line_type, inclusion: { in: LINE_TYPES }
  validates :quantity, numericality: { greater_than_or_equal_to: 0 }
  validates :discount_amount, numericality: true

  before_validation :set_defaults

  private

  def set_defaults
    self.line_type = "product" if line_type.blank?
    self.quantity = 1 if quantity.blank?
    self.discount_amount = 0 if discount_amount.blank?
  end
end
