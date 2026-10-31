import pytest
from fastmcp import Client

from app.core import supabase
from app.core.consulta import MSG_ERRO_BANCO
from app.server import criar_servidor

FERRAMENTAS = {
    "info_loja", "resumo_funil", "leads_por_origem", "desempenho_vendedores",
    "motivos_perda", "leads_parados", "buscar_lead", "detalhar_lead", "tarefas",
    "estoque_veiculos", "vendas_periodo",
    "chat_visao_geral", "tempo_resposta", "conversas_sem_resposta", "followup_ausente",
    "ligacoes", "mapa_demanda", "conversas_orfas", "chat_x_conversao",
    "conversao_etapas", "distribuicao_leads", "leads_sem_contato",
    "desempenho_anuncios", "resultado_campanhas", "demanda_x_estoque",
}
PIPELINE = "6f1c2b9e-3a4d-4e5f-8a9b-0c1d2e3f4a5b"
LEAD = "0b7e8c2a-1d3f-4a5b-9c6d-7e8f9a0b1c2d"


def _params(fake_banco, funcao):
    return [c[2] for c in fake_banco["chamadas"] if c[0] == funcao][-1]


async def test_todas_as_ferramentas_sao_somente_leitura(fake_banco):
    async with Client(criar_servidor()) as client:
        ferramentas = await client.list_tools()
    assert {t.name for t in ferramentas} == FERRAMENTAS
    assert all(t.annotations and t.annotations.read_only_hint for t in ferramentas)


async def test_resumo_funil_periodo_e_pipeline(fake_banco):
    fake_banco["respostas"]["mcp_resumo_funil"] = {"vendas": 3}
    async with Client(criar_servidor()) as client:
        r = await client.call_tool(
            "resumo_funil", {"inicio": "2026-09-01", "fim": "2026-09-30", "pipeline_id": PIPELINE}
        )
    assert r.data == {"vendas": 3}
    assert _params(fake_banco, "mcp_resumo_funil") == {
        "p_inicio": "2026-09-01", "p_fim": "2026-09-30", "p_pipeline": PIPELINE,
    }


@pytest.mark.parametrize(
    ("ferramenta", "args"),
    [
        ("detalhar_lead", {"lead_id": "lead-123"}),
        ("resumo_funil", {"pipeline_id": "Pipeline Principal"}),
        ("leads_parados", {"etapa_id": "x"}),
        ("tempo_resposta", {"instancia_id": "WhatsApp 1"}),
    ],
)
async def test_id_que_nao_e_uuid_nao_chama_banco(fake_banco, ferramenta, args):
    async with Client(criar_servidor()) as client:
        r = await client.call_tool(ferramenta, args, raise_on_error=False)
    assert r.is_error
    assert f"mcp_{ferramenta}" not in [c[0] for c in fake_banco["chamadas"]]


async def test_periodo_invalido_nao_chama_banco(fake_banco):
    async with Client(criar_servidor()) as client:
        r = await client.call_tool(
            "vendas_periodo", {"inicio": "2026-01-01", "fim": "2026-12-31"}, raise_on_error=False
        )
    assert r.is_error and "93 dias" in r.content[0].text
    assert "mcp_vendas_periodo" not in [c[0] for c in fake_banco["chamadas"]]


async def test_parametro_invalido_do_banco_vira_mensagem(fake_banco):
    fake_banco["respostas"]["mcp_buscar_lead"] = supabase.ParametroInvalido(
        "informe ao menos 3 caracteres"
    )
    async with Client(criar_servidor()) as client:
        r = await client.call_tool("buscar_lead", {"termo": "abc"}, raise_on_error=False)
    assert r.is_error and "3 caracteres" in r.content[0].text


async def test_erro_generico_nao_vaza_detalhes(fake_banco):
    fake_banco["respostas"]["mcp_tarefas"] = supabase.ErroBanco("mcp_tarefas: HTTP 500 detalhe interno")
    async with Client(criar_servidor()) as client:
        r = await client.call_tool("tarefas", {}, raise_on_error=False)
    assert r.is_error
    assert r.content[0].text.endswith(MSG_ERRO_BANCO)
    assert "detalhe interno" not in r.content[0].text


async def test_telefones_mascarados_na_saida(fake_banco):
    fake_banco["respostas"]["mcp_leads_parados"] = {
        "total": 1, "leads": [{"nome": "Ana", "telefone": "5547996769409"}],
    }
    async with Client(criar_servidor()) as client:
        r = await client.call_tool("leads_parados", {"dias": 15})
    assert r.data["leads"][0]["telefone"] == "(47) 9****-9409"
    assert _params(fake_banco, "mcp_leads_parados")["p_dias"] == 15


async def test_detalhar_lead_inexistente(fake_banco):
    fake_banco["respostas"]["mcp_detalhar_lead"] = None
    async with Client(criar_servidor()) as client:
        r = await client.call_tool("detalhar_lead", {"lead_id": LEAD}, raise_on_error=False)
    assert r.is_error and "não encontrado" in r.content[0].text


async def test_estoque_todos_envia_status_nulo(fake_banco):
    fake_banco["respostas"]["mcp_estoque_veiculos"] = {}
    async with Client(criar_servidor()) as client:
        await client.call_tool("estoque_veiculos", {"status": "todos"})
    assert _params(fake_banco, "mcp_estoque_veiculos")["p_status"] is None


@pytest.mark.parametrize("agrupar", ["bimestre", ""])
async def test_agrupamento_invalido_rejeitado_pelo_schema(fake_banco, agrupar):
    async with Client(criar_servidor()) as client:
        r = await client.call_tool("vendas_periodo", {"agrupar_por": agrupar}, raise_on_error=False)
    assert r.is_error
    assert "mcp_vendas_periodo" not in [c[0] for c in fake_banco["chamadas"]]
