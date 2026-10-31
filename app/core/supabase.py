"""Cliente PostgREST que sempre consulta com o JWT do próprio usuário.

Nunca usa service_role: a RLS e as funções mcp_* fazem o isolamento por loja.
"""

from typing import Any

import httpx

from app.core.config import get_settings

_client: httpx.AsyncClient | None = None

MSG_ID_INVALIDO = (
    "Identificador inválido. Use os ids retornados por `info_loja` ou pelas outras ferramentas."
)


class AcessoNegadoBanco(Exception):
    """O banco recusou a chamada (mcp_exigir_admin ou RLS)."""


class ParametroInvalido(Exception):
    """Validação de parâmetro feita pela função SQL (errcode 22023)."""


class ConsultaDemorada(Exception):
    """Estourou o statement_timeout do role authenticated (8s)."""


class ErroBanco(Exception):
    pass


def _http() -> httpx.AsyncClient:
    global _client
    if _client is None:
        settings = get_settings()
        _client = httpx.AsyncClient(
            base_url=f"{settings.SUPABASE_URL.rstrip('/')}/rest/v1",
            headers={"apikey": settings.SUPABASE_ANON_KEY},
            timeout=httpx.Timeout(15.0, connect=5.0),
        )
    return _client


async def rpc(funcao: str, token: str, params: dict[str, Any] | None = None) -> Any:
    response = await _http().post(
        f"/rpc/{funcao}",
        json=params or {},
        headers={"Authorization": f"Bearer {token}"},
    )
    if response.status_code < 400:
        return response.json() if response.content else None

    try:
        corpo = response.json()
    except ValueError:
        corpo = {}
    # 42501 = insufficient_privilege (mcp_exigir_admin); 401/403 = token/RLS
    if corpo.get("code") == "42501" or response.status_code in (401, 403):
        raise AcessoNegadoBanco(corpo.get("message") or "acesso negado")
    if corpo.get("code") == "57014":
        raise ConsultaDemorada(funcao)
    if corpo.get("code") == "22023":
        raise ParametroInvalido(str(corpo.get("message", "")).removeprefix("mcp: "))
    # 22P02 = invalid_text_representation (ex.: id que não é UUID)
    if corpo.get("code") == "22P02":
        raise ParametroInvalido(MSG_ID_INVALIDO)
    raise ErroBanco(f"{funcao}: HTTP {response.status_code} {corpo.get('message', '')}".strip())


async def fechar() -> None:
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None
