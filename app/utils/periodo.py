from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from fastmcp.exceptions import ToolError

FUSO = ZoneInfo("America/Sao_Paulo")
DIAS_PADRAO = 30
DIAS_MAXIMO = 93


def hoje() -> date:
    return datetime.now(FUSO).date()


def resolver(inicio: date | None, fim: date | None) -> tuple[date, date]:
    """Período inclusivo. Sem datas: últimos 30 dias até hoje (fuso de São Paulo)."""
    fim = fim or hoje()
    inicio = inicio or fim - timedelta(days=DIAS_PADRAO - 1)
    if fim < inicio:
        raise ToolError("A data final é anterior à data inicial.")
    if (fim - inicio).days + 1 > DIAS_MAXIMO:
        raise ToolError(
            f"O período máximo é de {DIAS_MAXIMO} dias. Divida a análise em períodos menores."
        )
    return inicio, fim
