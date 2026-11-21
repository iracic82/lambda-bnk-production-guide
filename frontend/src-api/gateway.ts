// Inference Gateway hooks (contracts/inference-gateway.openapi.yaml). Every mutation keeps the exact
// request/response it sent in `exchange`, which pages render with <ApiCall>.
import { useMutation, useQuery, useQueryClient, type QueryKey } from '@tanstack/react-query'
import { useState } from 'react'
import { api, type Exchange } from './client'
import type { components } from './schema/gateway'

type S = components['schemas']
export type InferenceEndpoint = S['InferenceEndpoint']
export type EndpointStatus = S['EndpointStatus']
export type Policy = S['Policy']
export type PolicyKind = S['PolicyKind']
export type PolicyStatus = S['PolicyStatus']
export type PolicyUpdate = S['PolicyUpdate']
export type TokenQuotaConfig = S['TokenQuotaConfig']
export type ModelScheduleConfig = S['ModelScheduleConfig']
export type AiLoadBalancingConfig = S['AiLoadBalancingConfig']
export type NetworkFirewallConfig = S['NetworkFirewallConfig']
export type Utilization = S['Utilization']
export type InstanceUtilization = S['InstanceUtilization']
export type UsageSummary = S['UsageSummary']
export type UsageRow = S['UsageRow']
export type BenchmarkRun = S['BenchmarkRun']
export type BenchmarkWorkload = S['BenchmarkWorkload']
export type BenchmarkModeResult = S['BenchmarkModeResult']
export type ChatResult = S['ChatResult']
export type ChatRequest = {
  endpoint_id: string
  api_key?: string | null
  user?: string | null
  model?: string | null
  messages: { role: 'system' | 'user' | 'assistant'; content: string }[]
  max_tokens?: number
}
import type { operations } from './schema/gateway'
export type GatewayStatus = operations['getInferenceGatewayStatus']['responses'][200]['content']['application/json']['data']
export type DataPlane = { healthy: boolean; last_check: string | null; detail: string | null }
/** Data-plane health; falls back to the legacy boolean for adapters that don't send `data_plane` yet. */
export const dataPlane = (s: GatewayStatus): DataPlane => s.data_plane ?? { healthy: s.data_plane_healthy, last_check: null, detail: null }

const BASE = '/api/v1/inference-endpoints'
const OPS = '/api/v1/inference-endpoint-operations'
const POLL_MS = 3000

const busyEndpoint = (e?: InferenceEndpoint) =>
  !!e && (e.status === 'provisioning' || e.status === 'deleting' || e.policies.some((p) => p.status === 'applying'))
const busyRun = (r?: BenchmarkRun) => !!r && r.status !== 'completed' && r.status !== 'failed'

export const useGatewayStatus = () =>
  useQuery({ queryKey: ['ie', 'status'], queryFn: () => api<GatewayStatus>('/api/v1/inference-gateway/status'), staleTime: 15_000, refetchInterval: 30_000 })

export const useEndpoints = () =>
  useQuery({
    queryKey: ['ie', 'list'],
    queryFn: () => api<InferenceEndpoint[]>(BASE),
    refetchInterval: (q) => (q.state.data?.some(busyEndpoint) ? POLL_MS : false),
  })

export const useEndpoint = (id: string) =>
  useQuery({
    queryKey: ['ie', 'one', id],
    queryFn: () => api<InferenceEndpoint>(`${BASE}/${id}`),
    refetchInterval: (q) => (busyEndpoint(q.state.data) ? POLL_MS : false),
  })

export const useUsage = (id: string, enabled = true) =>
  useQuery({ queryKey: ['ie', 'usage', id], queryFn: () => api<UsageSummary>(`${BASE}/${id}/usage`), enabled, refetchInterval: 10_000 })

export const useUtilization = (id: string, enabled = true) =>
  useQuery({ queryKey: ['ie', 'util', id], queryFn: () => api<Utilization>(`${BASE}/${id}/utilization`), enabled, refetchInterval: 5_000 })

export const useBenchmarks = (id: string, enabled = true) =>
  useQuery({
    queryKey: ['ie', 'bench', id],
    queryFn: () => api<BenchmarkRun[]>(`${BASE}/${id}/benchmarks`),
    enabled,
    refetchInterval: (q) => (busyRun(q.state.data?.[0]) ? POLL_MS : false),
  })

/** A mutation that also remembers the last request/response it sent. */
function useRecorded<V, R>(fn: (v: V, record: (e: Exchange) => void) => Promise<R>, invalidate: (v: V) => QueryKey[]) {
  const qc = useQueryClient()
  const [exchange, setExchange] = useState<Exchange | null>(null)
  const m = useMutation({
    mutationFn: (v: V) => fn(v, setExchange),
    onSettled: (_d, _e, v) => Promise.all(invalidate(v).map((queryKey) => qc.invalidateQueries({ queryKey }))),
  })
  return { ...m, exchange, clearExchange: () => setExchange(null) }
}

export const useCreateEndpoint = () =>
  useRecorded((body: { name: string; instance_ids: string[] }, record) => api<InferenceEndpoint>(BASE, { method: 'POST', body, record }), () => [['ie', 'list']])

export const useUpdateEndpoint = (id: string) =>
  useRecorded(
    (body: { name?: string; instance_ids?: string[] }, record) => api<InferenceEndpoint>(`${BASE}/${id}`, { method: 'POST', body, record }),
    () => [['ie']],
  )

export const useDeleteEndpoint = () =>
  useRecorded((id: string, record) => api<InferenceEndpoint>(`${BASE}/${id}`, { method: 'DELETE', record }), () => [['ie']])

export const useUpdatePolicy = (id: string) =>
  useRecorded(
    ({ kind, ...body }: PolicyUpdate & { kind: PolicyKind }, record) => api<Policy>(`${BASE}/${id}/policies/${kind}`, { method: 'PATCH', body, record }),
    () => [['ie', 'one', id], ['ie', 'list']],
  )

export const useResetUsage = (id: string) =>
  useRecorded((_: void, record) => api<Record<string, never>>(`${OPS}/reset-usage`, { method: 'POST', body: { endpoint_id: id }, record }), () => [['ie', 'usage', id]])

export const useRunBenchmark = (id: string) =>
  useRecorded(
    (workload: BenchmarkWorkload | undefined, record) =>
      api<BenchmarkRun>(`${OPS}/benchmark`, { method: 'POST', body: { endpoint_id: id, ...(workload ? { workload } : {}) }, record }),
    () => [['ie', 'bench', id]],
  )

export const useChat = (id: string) =>
  useRecorded((body: ChatRequest, record) => api<ChatResult>(`${OPS}/chat`, { method: 'POST', body, record }), () => [['ie', 'usage', id]])
