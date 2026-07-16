// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

let pendingDeleteForm = null

const closeDeleteConfirmModal = () => {
  const modal = document.querySelector("[data-delete-confirm-modal]")
  if (!modal) return

  modal.hidden = true
  pendingDeleteForm = null
}

const openDeleteConfirmModal = (form) => {
  const modal = document.querySelector("[data-delete-confirm-modal]")
  if (!modal) return false

  pendingDeleteForm = form
  modal.hidden = false
  modal.querySelector("[data-delete-confirm-cancel-button]")?.focus()
  return true
}

document.addEventListener("submit", (event) => {
  const form = event.target
  if (!(form instanceof HTMLFormElement) || !form.dataset.deleteConfirm) return
  if (form.dataset.deleteConfirmed === "true") return

  event.preventDefault()
  openDeleteConfirmModal(form)
})

document.addEventListener("click", (event) => {
  if (event.target.closest("[data-delete-confirm-cancel]")) {
    closeDeleteConfirmModal()
    return
  }

  if (event.target.closest("[data-delete-confirm-accept]") && pendingDeleteForm) {
    const form = pendingDeleteForm
    form.dataset.deleteConfirmed = "true"
    closeDeleteConfirmModal()
    form.requestSubmit()
  }
})

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") closeDeleteConfirmModal()
})
