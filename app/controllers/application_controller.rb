require "digest"

class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :require_app_access!

  private

  def require_app_access!
    return unless access_lock_enabled?
    return if app_access_unlocked?

    store_access_return_path
    redirect_to new_access_path
  end

  def access_lock_enabled?
    ENV.fetch("APP_ACCESS_LOCK_ENABLED", "false").casecmp?("true")
  end

  def app_access_unlocked?
    expires_at = session[:app_access_expires_at].to_i
    return true if expires_at > Time.current.to_i

    session.delete(:app_access_expires_at)
    false
  end

  def app_access_password_configured?
    ENV["APP_ACCESS_PASSWORD"].present?
  end

  def valid_app_access_password?(submitted_password)
    return false unless app_access_password_configured? && submitted_password.present?

    submitted_digest = Digest::SHA256.hexdigest(submitted_password)
    configured_digest = Digest::SHA256.hexdigest(ENV.fetch("APP_ACCESS_PASSWORD"))
    ActiveSupport::SecurityUtils.secure_compare(submitted_digest, configured_digest)
  end

  def unlock_app_access!
    session[:app_access_expires_at] = 24.hours.from_now.to_i
  end

  def access_return_path
    path = session.delete(:app_access_return_path)
    path.is_a?(String) && path.start_with?("/") && !path.start_with?("//") ? path : root_path
  end

  def store_access_return_path
    session[:app_access_return_path] = request.fullpath if request.get?
  end
end
