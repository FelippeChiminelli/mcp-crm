import pytest
from fastmcp import Client, FastMCP

from app.core import access, supabase
from app.server import criar_servidor


def _servidor_com_ferramenta_de_chat() -> FastMCP:
    mcp = criar_servidor()

    @mcp.tool(tags={access.TAG_CONTEUDO_CHAT})
    async def ler_conversa_teste() -> str:
        return "conteudo"

    return mcp


async def test_admin_habilitado_chama_info_loja(fake_banco):
    fake_banco["respostas"]["mcp_info_loja"] = {"loja": {"nome": "Loja A"}}
    async with Client(criar_servidor()) as client:
        resultado = await client.call_tool("info_loja", {})
    assert resultado.data == {"loja": {"nome": "Loja A"}}
    funcoes = [c[0] for c in fake_banco["chamadas"]]
    assert "mcp_info_loja" in funcoes
    # Sempre com o token do usuário
    assert all(c[1] == "jwt-teste" for c in fake_banco["chamadas"])


@pytest.mark.parametrize(
    ("campo", "mensagem"),
    [
        ("is_admin", access.MSG_NAO_ADMIN),
        ("empresa_ativa", access.MSG_LOJA_INATIVA),
        ("habilitado", access.MSG_NAO_HABILITADO),
    ],
)
async def test_bloqueios(fake_banco, campo, mensagem):
    fake_banco["contexto"][campo] = False
    async with Client(criar_servidor()) as client:
        resultado = await client.call_tool("info_loja", {}, raise_on_error=False)
    assert resultado.is_error
    assert mensagem in resultado.content[0].text
    assert "mcp_info_loja" not in [c[0] for c in fake_banco["chamadas"]]


async def test_sem_perfil(fake_banco):
    fake_banco["contexto"] = None
    async with Client(criar_servidor()) as client:
        resultado = await client.call_tool("info_loja", {}, raise_on_error=False)
    assert resultado.is_error
    assert access.MSG_SEM_PERFIL in resultado.content[0].text


async def test_sem_token(fake_banco, monkeypatch):
    monkeypatch.setattr("app.core.access.get_access_token", lambda: None)
    async with Client(criar_servidor()) as client:
        resultado = await client.call_tool("info_loja", {}, raise_on_error=False)
    assert resultado.is_error
    assert access.MSG_SEM_LOGIN in resultado.content[0].text


async def test_banco_nega_mesmo_com_middleware_liberando(fake_banco):
    fake_banco["respostas"]["mcp_info_loja"] = supabase.AcessoNegadoBanco("mcp: acesso negado")
    async with Client(criar_servidor()) as client:
        resultado = await client.call_tool("info_loja", {}, raise_on_error=False)
    assert resultado.is_error
    assert access.MSG_NAO_HABILITADO in resultado.content[0].text


async def test_ferramenta_de_conteudo_oculta_e_bloqueada(fake_banco):
    async with Client(_servidor_com_ferramenta_de_chat()) as client:
        nomes = {t.name for t in await client.list_tools()}
        resultado = await client.call_tool("ler_conversa_teste", {}, raise_on_error=False)
    assert "info_loja" in nomes
    assert "ler_conversa_teste" not in nomes
    assert resultado.is_error
    assert access.MSG_SEM_CONTEUDO_CHAT in resultado.content[0].text


async def test_ferramenta_de_conteudo_liberada(fake_banco):
    fake_banco["contexto"]["permite_conteudo_chat"] = True
    async with Client(_servidor_com_ferramenta_de_chat()) as client:
        nomes = {t.name for t in await client.list_tools()}
        resultado = await client.call_tool("ler_conversa_teste", {})
    assert "ler_conversa_teste" in nomes
    assert resultado.data == "conteudo"


async def test_auditoria_registra_sucesso_e_negacao(fake_banco):
    fake_banco["respostas"]["mcp_info_loja"] = {}
    async with Client(criar_servidor()) as client:
        await client.call_tool("info_loja", {})
        fake_banco["contexto"]["habilitado"] = False
        access.limpar_cache()
        await client.call_tool("info_loja", {}, raise_on_error=False)

    logs = [c[2] for c in fake_banco["chamadas"] if c[0] == "mcp_log_call"]
    assert len(logs) == 2
    assert logs[0]["p_ferramenta"] == "info_loja" and logs[0]["p_erro"] is None
    assert access.MSG_NAO_HABILITADO in logs[1]["p_erro"]


async def test_cache_remove_entradas_expiradas(fake_banco):
    access._cache["sub-antigo"] = (0.0, {"empresa_id": "x"})
    fake_banco["respostas"]["mcp_info_loja"] = {}
    async with Client(criar_servidor()) as client:
        await client.call_tool("info_loja", {})
    assert set(access._cache) == {"u-admin"}


async def test_cache_de_contexto(fake_banco):
    fake_banco["respostas"]["mcp_info_loja"] = {}
    async with Client(criar_servidor()) as client:
        await client.call_tool("info_loja", {})
        await client.call_tool("info_loja", {})
    assert [c[0] for c in fake_banco["chamadas"]].count("mcp_contexto") == 1
