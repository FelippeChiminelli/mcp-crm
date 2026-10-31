from datetime import date, timedelta

import pytest
from fastmcp.exceptions import ToolError

from app.utils import comparacao, mascara, periodo


@pytest.mark.parametrize(
    ("entrada", "esperado"),
    [
        ("5547996769409", "(47) 9****-9409"),
        ("47 99676-9409", "(47) 9****-9409"),
        ("554733334444", "(47) 3****-4444"),
        ("99676940", "****-6940"),
        ("123", "****"),
        ("", ""),
        (None, None),
    ],
)
def test_telefone(entrada, esperado):
    assert mascara.telefone(entrada) == esperado


def test_email():
    assert mascara.email("felippe@gmail.com") == "f***@gmail.com"
    assert mascara.email("sem-arroba") == "sem-arroba"


def test_mascarar_recursivo():
    dados = {
        "lead": {"telefone": "5547996769409", "email": "ana@x.com", "nome": "Ana"},
        "leads": [{"telefone": "5547996769409", "valor": 10}],
        "telefone": None,
    }
    assert mascara.mascarar(dados) == {
        "lead": {"telefone": "(47) 9****-9409", "email": "a***@x.com", "nome": "Ana"},
        "leads": [{"telefone": "(47) 9****-9409", "valor": 10}],
        "telefone": None,
    }


def test_periodo_padrao_30_dias():
    ini, fim = periodo.resolver(None, None)
    assert fim == periodo.hoje()
    assert (fim - ini).days == 29


def test_periodo_explicito():
    assert periodo.resolver(date(2026, 9, 1), date(2026, 9, 30)) == (date(2026, 9, 1), date(2026, 9, 30))


def test_periodo_invertido():
    with pytest.raises(ToolError, match="anterior"):
        periodo.resolver(date(2026, 9, 30), date(2026, 9, 1))


def test_periodo_anterior_mesmo_tamanho():
    assert comparacao.periodo_anterior(date(2026, 10, 1), date(2026, 10, 31)) == (
        date(2026, 8, 31), date(2026, 9, 30),
    )
    assert comparacao.periodo_anterior(date(2026, 10, 25), date(2026, 10, 31)) == (
        date(2026, 10, 18), date(2026, 10, 24),
    )


def test_variacoes_ignora_nao_numericos_e_base_zero():
    atual = {"vendas": 12, "valor": 150000.5, "ticket": None, "ok": True, "nome": "x", "perdas": 3}
    anterior = {"vendas": 10, "valor": 100000, "ticket": 9000, "ok": False, "nome": "y", "perdas": 0}
    assert comparacao.variacoes(atual, anterior) == {
        "vendas": {"atual": 12, "anterior": 10, "diferenca": 2, "variacao_pct": 20.0},
        "valor": {"atual": 150000.5, "anterior": 100000, "diferenca": 50000.5, "variacao_pct": 50.0},
        "perdas": {"atual": 3, "anterior": 0, "diferenca": 3, "variacao_pct": None},
    }


def test_periodo_maximo():
    inicio = date(2026, 1, 1)
    periodo.resolver(inicio, inicio + timedelta(days=92))
    with pytest.raises(ToolError, match="93 dias"):
        periodo.resolver(inicio, inicio + timedelta(days=93))
