"""Isolamento entre lojas contra o Supabase real (spec, seção 8). Bloqueante para produção.

Usa os usuários de teste das lojas "MCP Teste A" e "MCP Teste B" (nunca lojas reais),
com as duas lojas habilitadas em mcp_empresa_config. Só roda com as variáveis:

    SUPABASE_URL, SUPABASE_ANON_KEY            (projeto real)
    MCP_TESTE_ADMIN_A_EMAIL, MCP_TESTE_ADMIN_B_EMAIL, MCP_TESTE_VENDEDOR_A_EMAIL
    MCP_TESTE_SENHA                            (mesma senha para os três)

    uv run pytest -m integracao
"""

import os
from datetime import date, timedelta

import httpx
import pytest

from app.core import supabase
from app.core.config import get_settings

VARIAVEIS = (
    "MCP_TESTE_ADMIN_A_EMAIL",
    "MCP_TESTE_ADMIN_B_EMAIL",
    "MCP_TESTE_VENDEDOR_A_EMAIL",
    "MCP_TESTE_SENHA",
)

pytestmark = [
    pytest.mark.integracao,
    pytest.mark.skipif(
        any(not os.environ.get(v) for v in VARIAVEIS)
        or "exemplo.supabase.co" in os.environ.get("SUPABASE_URL", ""),
        reason="credenciais dos usuários de teste não configuradas",
    ),
]

FIM = date.today()
PERIODO = {"p_inicio": (FIM - timedelta(days=6)).isoformat(), "p_fim": FIM.isoformat()}

# Uma função de cada migration; o vendedor tem que ser barrado em todas
FUNCOES_DE_DADOS = [
    ("mcp_info_loja", None),
    ("mcp_resumo_funil", PERIODO),
    ("mcp_tempo_resposta", PERIODO),
    ("mcp_listar_conversas", PERIODO),
]


async def _login(variavel_email: str) -> str:
    settings = get_settings()
    async with httpx.AsyncClient() as http:
        resposta = await http.post(
            f"{settings.SUPABASE_URL.rstrip('/')}/auth/v1/token",
            params={"grant_type": "password"},
            headers={"apikey": settings.SUPABASE_ANON_KEY},
            json={"email": os.environ[variavel_email], "password": os.environ["MCP_TESTE_SENHA"]},
        )
    resposta.raise_for_status()
    return resposta.json()["access_token"]


async def _algum_lead(token: str) -> str | None:
    settings = get_settings()
    async with httpx.AsyncClient() as http:
        resposta = await http.get(
            f"{settings.SUPABASE_URL.rstrip('/')}/rest/v1/leads",
            params={"select": "id", "limit": "1"},
            headers={"apikey": settings.SUPABASE_ANON_KEY, "Authorization": f"Bearer {token}"},
        )
    resposta.raise_for_status()
    linhas = resposta.json()
    return linhas[0]["id"] if linhas else None


@pytest.fixture(autouse=True)
async def _cliente_por_teste():
    # O cliente httpx global fica preso ao event loop do teste que o criou
    yield
    await supabase.fechar()


async def test_admins_veem_so_a_propria_loja():
    token_a = await _login("MCP_TESTE_ADMIN_A_EMAIL")
    token_b = await _login("MCP_TESTE_ADMIN_B_EMAIL")

    loja_a = (await supabase.rpc("mcp_info_loja", token_a))["loja"]["id"]
    loja_b = (await supabase.rpc("mcp_info_loja", token_b))["loja"]["id"]
    assert loja_a != loja_b

    lead_b = await _algum_lead(token_b)
    assert lead_b, "a loja de teste B precisa ter ao menos um lead"
    assert await supabase.rpc("mcp_detalhar_lead", token_a, {"p_lead_id": lead_b}) is None


@pytest.mark.parametrize(("funcao", "params"), FUNCOES_DE_DADOS)
async def test_vendedor_barrado_direto_na_rpc(funcao, params):
    token = await _login("MCP_TESTE_VENDEDOR_A_EMAIL")
    with pytest.raises(supabase.AcessoNegadoBanco):
        await supabase.rpc(funcao, token, params)


async def test_vendedor_ve_o_proprio_contexto_sem_admin():
    token = await _login("MCP_TESTE_VENDEDOR_A_EMAIL")
    contexto = await supabase.rpc("mcp_contexto", token)
    assert contexto["is_admin"] is False


async def test_token_invalido_e_recusado():
    with pytest.raises(supabase.AcessoNegadoBanco):
        await supabase.rpc("mcp_info_loja", "token-invalido")
