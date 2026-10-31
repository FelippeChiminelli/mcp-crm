import pytest
from fastmcp import Client

from app.core import supabase
from app.core.consulta import MSG_CONSULTA_DEMORADA
from app.server import criar_servidor
from app.tools.atendimento import OBS_HORARIO


def _params(fake_banco, funcao):
    return [c[2] for c in fake_banco["chamadas"] if c[0] == funcao][-1]


async def test_tempo_resposta_parametros(fake_banco):
    fake_banco["respostas"]["mcp_tempo_resposta"] = {"grupos": []}
    async with Client(criar_servidor()) as client:
        await client.call_tool(
            "tempo_resposta",
            {"inicio": "2026-10-01", "fim": "2026-10-15", "agrupar_por": "hora",
             "excluir_instancias_com_ia": True, "instancia_id": "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"},
        )
    assert _params(fake_banco, "mcp_tempo_resposta") == {
        "p_inicio": "2026-10-01", "p_fim": "2026-10-15", "p_agrupar": "hora",
        "p_excluir_ia": True, "p_instancia": "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d",
    }


async def test_docstrings_lembram_horario_de_funcionamento(fake_banco):
    async with Client(criar_servidor()) as client:
        ferramentas = {t.name: t for t in await client.list_tools()}
    for nome in ("tempo_resposta", "conversas_sem_resposta"):
        assert OBS_HORARIO in ferramentas[nome].description


async def test_sem_resposta_padroes_e_mascara(fake_banco):
    fake_banco["respostas"]["mcp_conversas_sem_resposta"] = {
        "total": 1, "conversas": [{"telefone": "5547997084799", "minutos_esperando": 90}],
    }
    async with Client(criar_servidor()) as client:
        r = await client.call_tool("conversas_sem_resposta", {})
    assert r.data["conversas"][0]["telefone"] == "(47) 9****-4799"
    assert _params(fake_banco, "mcp_conversas_sem_resposta") == {
        "p_minutos": 30, "p_max_dias": 7, "p_vendedor": None, "p_instancia": None, "p_limite": 50,
    }


async def test_ligacoes_prazo_fora_do_limite(fake_banco):
    async with Client(criar_servidor()) as client:
        r = await client.call_tool("ligacoes", {"horas_retorno": 100}, raise_on_error=False)
    assert r.is_error
    assert "mcp_ligacoes" not in [c[0] for c in fake_banco["chamadas"]]


async def test_consulta_demorada_vira_orientacao(fake_banco):
    fake_banco["respostas"]["mcp_chat_x_conversao"] = supabase.ConsultaDemorada("mcp_chat_x_conversao")
    async with Client(criar_servidor()) as client:
        r = await client.call_tool("chat_x_conversao", {}, raise_on_error=False)
    assert r.is_error and MSG_CONSULTA_DEMORADA in r.content[0].text


@pytest.mark.parametrize(
    ("ferramenta", "funcao"),
    [
        ("chat_visao_geral", "mcp_chat_visao_geral"),
        ("followup_ausente", "mcp_followup_ausente"),
        ("mapa_demanda", "mcp_mapa_demanda"),
        ("conversas_orfas", "mcp_conversas_orfas"),
    ],
)
async def test_ferramentas_chamam_funcao_certa(fake_banco, ferramenta, funcao):
    fake_banco["respostas"][funcao] = [] if ferramenta == "mapa_demanda" else {}
    async with Client(criar_servidor()) as client:
        await client.call_tool(ferramenta, {})
    assert funcao in [c[0] for c in fake_banco["chamadas"]]
