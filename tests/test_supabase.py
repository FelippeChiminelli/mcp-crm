import httpx
import pytest

from app.core import supabase


@pytest.fixture
def transporte(monkeypatch):
    estado = {}

    def usar(handler):
        cliente = httpx.AsyncClient(
            base_url="https://exemplo.supabase.co/rest/v1",
            headers={"apikey": "anon-teste"},
            transport=httpx.MockTransport(handler),
        )
        monkeypatch.setattr(supabase, "_client", cliente)
        return estado

    return usar


async def test_rpc_envia_token_do_usuario(transporte):
    capturado = {}

    def handler(request: httpx.Request):
        capturado["auth"] = request.headers["authorization"]
        capturado["apikey"] = request.headers["apikey"]
        capturado["path"] = request.url.path
        return httpx.Response(200, json={"ok": True})

    transporte(handler)
    assert await supabase.rpc("mcp_info_loja", "jwt-do-usuario") == {"ok": True}
    assert capturado == {
        "auth": "Bearer jwt-do-usuario",
        "apikey": "anon-teste",
        "path": "/rest/v1/rpc/mcp_info_loja",
    }


async def test_rpc_42501_vira_acesso_negado(transporte):
    transporte(lambda r: httpx.Response(403, json={"code": "42501", "message": "mcp: acesso negado"}))
    with pytest.raises(supabase.AcessoNegadoBanco):
        await supabase.rpc("mcp_info_loja", "jwt")


async def test_rpc_erro_generico(transporte):
    transporte(lambda r: httpx.Response(500, json={"message": "boom"}))
    with pytest.raises(supabase.ErroBanco):
        await supabase.rpc("mcp_info_loja", "jwt")


async def test_rpc_22p02_vira_id_invalido(transporte):
    transporte(lambda r: httpx.Response(400, json={"code": "22P02", "message": "invalid input syntax for type uuid"}))
    with pytest.raises(supabase.ParametroInvalido, match="Identificador inválido"):
        await supabase.rpc("mcp_detalhar_lead", "jwt", {"p_lead_id": "x"})


async def test_rpc_timeout_vira_consulta_demorada(transporte):
    transporte(lambda r: httpx.Response(500, json={"code": "57014", "message": "canceling statement"}))
    with pytest.raises(supabase.ConsultaDemorada):
        await supabase.rpc("mcp_mapa_demanda", "jwt")
