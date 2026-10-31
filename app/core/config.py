from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    SUPABASE_URL: str
    SUPABASE_ANON_KEY: str
    # URL pública deste servidor (ex.: https://mcp.auctatech.com.br)
    BASE_URL: str = "http://localhost:8000"
    SUPABASE_JWT_ALGORITHM: str = "ES256"
    # Segundos que o contexto do usuário (admin/loja habilitada) fica em cache
    CONTEXTO_CACHE_SEGUNDOS: int = 60
    LOG_LEVEL: str = "INFO"


@lru_cache
def get_settings() -> Settings:
    return Settings()  # pyright: ignore[reportCallIssue]
