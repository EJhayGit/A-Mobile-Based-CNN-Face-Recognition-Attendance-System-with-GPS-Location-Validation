FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    ENVIRONMENT=production \
    COOKIE_SECURE=true \
    BACKEND_HOST=0.0.0.0 \
    PORT=8080

WORKDIR /app

COPY backend/requirements.txt backend/requirements.txt
RUN python -m pip install --no-cache-dir -r backend/requirements.txt

COPY backend backend
COPY dashboard dashboard

RUN addgroup --system agila \
    && adduser --system --ingroup agila agila \
    && chown -R agila:agila /app

USER agila
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import os, urllib.request; host=os.environ['ALLOWED_HOSTS'].split(',')[0].strip(); request=urllib.request.Request('http://127.0.0.1:' + os.environ.get('PORT', '8080') + '/health', headers={'Host': host}); urllib.request.urlopen(request, timeout=3)"

CMD ["python", "-m", "backend.server"]
