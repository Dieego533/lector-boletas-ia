class AccessLocksController < ApplicationController
  skip_before_action :require_app_access!

  layout "access_lock"

  def new
    redirect_to access_return_path if !access_lock_enabled? || app_access_unlocked?
  end

  def create
    unless access_lock_enabled?
      redirect_to access_return_path
      return
    end

    unless app_access_password_configured?
      Rails.logger.error("[AccessLocksController] APP_ACCESS_PASSWORD is missing while access lock is enabled")
      flash.now[:alert] = "El acceso no está configurado. Contacta al administrador."
      render :new, status: :unprocessable_entity
      return
    end

    if valid_app_access_password?(params[:password])
      unlock_app_access!
      redirect_to access_return_path
      return
    end

    Rails.logger.warn("[AccessLocksController] invalid_access_password")
    flash.now[:alert] = "La clave de acceso no es correcta."
    render :new, status: :unprocessable_entity
  end
end
