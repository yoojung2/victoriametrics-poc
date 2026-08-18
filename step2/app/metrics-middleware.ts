import { Request, Response, NextFunction } from 'express';
import client from 'prom-client';

// 전용 레지스트리 + 기본 Node.js 프로세스 메트릭(CPU/메모리/GC 등) 자동 수집
const register = new client.Registry();
client.collectDefaultMetrics({ register });

// HTTP 요청 총 개수 (method/route/status 라벨)
const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status'] as const,
  registers: [register],
});

// HTTP 요청 처리 시간 히스토그램 (초 단위)
const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status'] as const,
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register],
});

export function metricsMiddleware(req: Request, res: Response, next: NextFunction) {
  const end = httpRequestDuration.startTimer();
  res.on('finish', () => {
    // 파라미터화된 경로(예: /api/products/:id) 사용해 라벨 카디널리티 폭발 방지
    // NOTE: express 서브라우터(app.use('/api/products', router)) 마운트 경로는
    //       req.route.path 가 '/' 로 잡힌다. 서브라우터별 세분화가 필요하면
    //       req.baseUrl + (req.route?.path||'') 를 route 라벨로 쓰면 된다.
    const route = (req.route?.path as string) || req.path || 'unknown';
    const labels = { method: req.method, route, status: String(res.statusCode) };
    httpRequestsTotal.inc(labels);
    end(labels);
  });
  next();
}

export async function metricsHandler(_req: Request, res: Response) {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
}
