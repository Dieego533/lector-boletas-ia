Rails.application.config.session_store :cookie_store,
  key: "_procesador_boletas_ia_session",
  expire_after: 24.hours,
  same_site: :lax
