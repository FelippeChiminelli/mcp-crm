import pytest
from fastmcp import Client

from app.core import supabase
from app.server import criar_servidor

PIPELINE = "6f1c2b9e-3a4d-4e5f-8a9b-0c1d2e3f4a5b"
VENDEDOR = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"


def _params(fake_banco, funcao):
    return [c[2] for c in fake_banco["chamadas"] if c[0] == funcao][-1]


def _funcoes(fake_banco):
    return [c[0] for c in fake_banco["chamadas"]]


@pytest.mark.parametrize(
    ("ferramenta", "args", "funcao", "esperado"),
    [
        ("conversao_etapas", {"pipeline_id": PIPELINE}, "mcp_conversao_etapas", {"p_pipeline": PIPELINE}),
        ("distribuicao_leads", {}, "mcp_distribuicao_leads", {"p_pipeline": None}),
        ("desempenho_anuncios", {"agrupar_por": "campanha"}, "mcp_desempenho_anuncios",
         {"p_agrupar": "campanha", "p_limite": 30}),
        ("resultado_campanhas", {"horas_resposta": 24}, "mcp_resultado_campanhas", {"p_horas_resposta": 24}),
        ("demanda_x_estoque", {"limite": 10}, "mcp_demanda_estoque", {"p_limite": 10}),
    ],
)
async def test_ferramentas_com_periodo(fake_banco, ferramenta, args, funcao, esperado):
    fake_banco["respostas"][funcao] = {"ok": True}
    async with Client(criar_servidor()) as client:
        r = await client.call_tool(ferramenta, {"inicio": "2026-09-01", "fim": "2026-09-30", **args})
    assert r.data == {"ok": True}
    params = _params(fake_banco, funcao)
    assert params["p_inicio"] == "2026-09-01" and params["p_fim"] == "2026-09-30"
    assert esperado.items() <= params.items()


async def test_leads_sem_contato_parametros_e_mascara(fake_banco):
    fake_banco["respostas"]["mcp_leads_sem_contato"] = {
        "total": 1, "leads": [{"nome": "Ana", "telefone": "5547996769409"}],
    }
    async with Client(criar_servidor()) as client:
        r = await client.call_tool(
            "leads_sem_contato", {"dias": 5, "max_dias": 30, "vendedor_id": VENDEDOR}
        )
    assert r.data["leads"][0]["telefone"] == "(47) 9****-9409"
    assert _params(fake_banco, "mcp_leads_sem_contato") == {
        "p_dias": 5, "p_max_dias": 30, "p_vendedor": VENDEDOR,
        "p_sem_responsavel": False, "p_limite": 50, "p_offset": 0,
    }


async def test_agrupamento_de_anuncios_invalido_nao_chama_banco(fake_banco):
    async with Client(criar_servidor()) as client:
        r = await client.call_tool("desempenho_anuncios", {"agrupar_por": "adset"}, raise_on_error=False)
    assert r.is_error
    assert "mcp_desempenho_anuncios" not in _funcoes(fake_banco)


async def test_resumo_funil_compara_com_periodo_anterior(fake_banco, monkeypatch):
    por_inicio = {
        "2026-10-01": {"vendas": 12, "novos_leads": 100, "etapas": []},
        "2026-08-31": {"vendas": 10, "novos_leads": 80, "etapas": []},
    }
    rpc_original = supabase.rpc

    async def rpc(funcao, tok, params=None):
        if funcao == "mcp_resumo_funil":
            fake_banco["chamadas"].append((funcao, tok, params))
            return por_inicio[params["p_inicio"]]
        return await rpc_original(funcao, tok, params)

    monkeypatch.setattr("app.core.supabase.rpc", rpc)
    async with Client(criar_servidor()) as client:
        r = await client.call_tool(
            "resumo_funil", {"inicio": "2026-10-01", "fim": "2026-10-31", "comparar_com_anterior": True}
        )

    chamadas = [c[2] for c in fake_banco["chamadas"] if c[0] == "mcp_resumo_funil"]
    assert {(p["p_inicio"], p["p_fim"]) for p in chamadas} == {
        ("2026-10-01", "2026-10-31"), ("2026-08-31", "2026-09-30"),
    }
    assert r.data["vendas"] == 12
    comparacao = r.data["comparacao_periodo_anterior"]
    assert comparacao["periodo"] == {"inicio": "2026-08-31", "fim": "2026-09-30"}
    assert comparacao["metricas"] == {
        "vendas": {"atual": 12, "anterior": 10, "diferenca": 2, "variacao_pct": 20.0},
        "novos_leads": {"atual": 100, "anterior": 80, "diferenca": 20, "variacao_pct": 25.0},
    }


async def test_vendas_periodo_compara_totais(fake_banco):
    fake_banco["respostas"]["mcp_vendas_periodo"] = {
        "series": [{"grupo": "a", "vendas": 2, "valor": 100}, {"grupo": "b", "vendas": 3, "valor": 50}],
        "vendas_com_valor_abaixo_de_1000": 1,
    }
    async with Client(criar_servidor()) as client:
        r = await client.call_tool("vendas_periodo", {"comparar_com_anterior": True})
    metricas = r.data["comparacao_periodo_anterior"]["metricas"]
    assert metricas["vendas"] == {"atual": 5, "anterior": 5, "diferenca": 0, "variacao_pct": 0.0}
    assert metricas["valor"]["atual"] == 150
    assert _funcoes(fake_banco).count("mcp_vendas_periodo") == 2


async def test_sem_comparar_chama_uma_vez(fake_banco):
    fake_banco["respostas"]["mcp_resumo_funil"] = {"vendas": 1}
    async with Client(criar_servidor()) as client:
        r = await client.call_tool("resumo_funil", {})
    assert "comparacao_periodo_anterior" not in r.data
    assert _funcoes(fake_banco).count("mcp_resumo_funil") == 1
