"""Comparação de métricas entre um período e o período anterior de mesmo tamanho."""

from datetime import date, timedelta
from numbers import Number
from typing import Any


def periodo_anterior(inicio: date, fim: date) -> tuple[date, date]:
    """Período imediatamente anterior, com a mesma quantidade de dias."""
    dias = (fim - inicio).days + 1
    fim_anterior = inicio - timedelta(days=1)
    return fim_anterior - timedelta(days=dias - 1), fim_anterior


def _numero(valor: Any) -> bool:
    return isinstance(valor, Number) and not isinstance(valor, bool)


def variacoes(atual: dict[str, Any], anterior: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Para cada métrica numérica presente nos dois lados: valores, diferença e variação %."""
    resultado = {}
    for chave, valor in atual.items():
        valor_anterior = anterior.get(chave)
        if not _numero(valor) or not _numero(valor_anterior):
            continue
        resultado[chave] = {
            "atual": valor,
            "anterior": valor_anterior,
            "diferenca": round(valor - valor_anterior, 2),
            "variacao_pct": (
                round(100 * (valor - valor_anterior) / valor_anterior, 1) if valor_anterior else None
            ),
        }
    return resultado
