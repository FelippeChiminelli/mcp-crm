FROM python:3.12-slim AS base

# Instalar UV (versão fixa para builds reproduzíveis)
COPY --from=ghcr.io/astral-sh/uv:0.10.2 /uv /uvx /bin/

# Variáveis de ambiente
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PATH="/app/.venv/bin:$PATH"

WORKDIR /app

# Instalar dependências primeiro (cache de layer)
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# Copiar código da aplicação
COPY app/ ./app/

# Rodar sem root
RUN useradd --system --uid 1001 app
USER app

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)"

# Atrás do proxy do Easypanel (Traefik): confiar nos cabeçalhos X-Forwarded-*
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--proxy-headers", "--forwarded-allow-ips", "*"]
