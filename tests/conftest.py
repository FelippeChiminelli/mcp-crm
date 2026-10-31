import os

import pytest

os.environ.setdefault("SUPABASE_URL", "https://exemplo.supabase.co")
os.environ.setdefault("SUPABASE_ANON_KEY", "anon-teste")

from fastmcp.server.auth.auth import AccessToken  # noqa: E402

from app.core import access  # noqa: E402

CONTEXTO_ADMIN = {
    "user_id": "u-admin",
    "nome": "Admin A",
    "empresa_id": "empresa-a",
    "empresa_nome": "Loja A",
    "is_admin": True,
    "empresa_ativa": True,
    "habilitado": True,
    "permite_conteudo_chat": False,
}


@pytest.fixture(autouse=True)
def _limpar_cache():
    access.limpar_cache()
    yield
    access.limpar_cache()


@pytest.fixture
def fake_banco(monkeypatch):
    """Simula o token do usuário e as RPCs do Supabase."""
    estado = {"contexto": dict(CONTEXTO_ADMIN), "chamadas": [], "respostas": {}}

    def token():
        return AccessToken(
            token="jwt-teste", client_id="cliente", scopes=[], claims={"sub": "u-admin"}
        )

    async def rpc(funcao, tok, params=None):
        estado["chamadas"].append((funcao, tok, params))
        if funcao == "mcp_contexto":
            return estado["contexto"]
        resposta = estado["respostas"].get(funcao)
        if isinstance(resposta, Exception):
            raise resposta
        return resposta

    monkeypatch.setattr("app.core.access.get_access_token", token)
    monkeypatch.setattr("app.core.audit.get_access_token", token)
    monkeypatch.setattr("app.core.supabase.rpc", rpc)
    return estado
