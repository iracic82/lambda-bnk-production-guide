// Network firewall hooks (specs/002-network-firewall/contracts/network-firewall.openapi.yaml), served by the adapter.
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, type Exchange } from './client'
import type { components } from './schema/firewall'

type S = components['schemas']
export type FirewallPolicy = S['FirewallPolicy']
export type FirewallRule = S['FirewallRule']
export type RuleAction = S['RuleAction']
export type DefaultAction = S['DefaultAction']
export type AddressList = S['AddressList']
export type PortList = S['PortList']
export type LogDestination = S['LogDestination']
export type FirewallEvent = S['FirewallEvent']
export type RuleHit = { rule: string; action: RuleAction; hits: number; last_hit: string | null }

export const FW = '/api/v1/network-firewall-'
export const isFirewallPath = (p: string) => p.startsWith(FW)

export type FwResource = 'policies' | 'address-lists' | 'port-lists' | 'log-destinations'

export const useFwList = <T,>(resource: FwResource) =>
  useQuery({ queryKey: ['fw', resource], queryFn: () => api<T[]>(`${FW}${resource}`) })

export const useFwEvents = (params: { endpoint_id?: string; action?: string; limit?: number }, refetch = 5000) => {
  const q = new URLSearchParams(Object.entries(params).filter(([, v]) => v !== undefined && v !== '').map(([k, v]) => [k, String(v)]))
  return useQuery({ queryKey: ['fw', 'events', params], queryFn: () => api<FirewallEvent[]>(`${FW}events?${q}`), refetchInterval: refetch })
}

export const useRuleHits = (policyId: string | null) =>
  useQuery({
    queryKey: ['fw', 'hits', policyId],
    queryFn: () => api<RuleHit[]>(`${FW}policies/${policyId}/rule-hits`),
    enabled: !!policyId,
    refetchInterval: 10_000,
  })

/** Create, update or delete one firewall object; remembers the exchange for <ApiCall>. */
export function useFwMutation(resource: FwResource) {
  const qc = useQueryClient()
  const [exchange, setExchange] = useState<Exchange | null>(null)
  const m = useMutation({
    mutationFn: ({ id, body, method }: { id?: string; body?: unknown; method: 'POST' | 'PATCH' | 'DELETE' }) =>
      api<unknown>(`${FW}${resource}${id ? `/${id}` : ''}`, { method, body, record: setExchange }),
    // Attached policies change endpoint state too (applying -> on).
    onSettled: () => Promise.all([qc.invalidateQueries({ queryKey: ['fw'] }), qc.invalidateQueries({ queryKey: ['ie'] })]),
  })
  return { ...m, exchange }
}
