import { httpRequest } from '../util/Http'
import type { HttpRequestConfig } from '../util/Http'
import PQueue from 'p-queue'
import type { WebhookServerChanConfig } from '../interface/Config'
import { flushQueue } from './Queue'

const serverChanQueue = new PQueue({
    interval: 1000,
    intervalCap: 2,
    carryoverConcurrencyCount: true
})

export async function sendServerChan(
    config: WebhookServerChanConfig,
    content: string,
    titleOverride?: string
): Promise<void> {
    if (!config?.sendkey) return

    const title = (titleOverride ?? config.title ?? 'Microsoft Rewards 通知').slice(0, 32)

    const request: HttpRequestConfig = {
        method: 'POST',
        url: `https://sctapi.ftqq.com/${config.sendkey}.send`,
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        data: new URLSearchParams({
            title,
            desp: content,
            ...(config.short ? { short: config.short.slice(0, 64) } : {})
        }).toString(),
        timeout: 10000
    }

    await serverChanQueue.add(async () => {
        try {
            await httpRequest(request)
        } catch (err) {
            const status = (err as { response?: { status?: number } })?.response?.status
            if (status === 429) return
        }
    })
}

export function flushServerChanQueue(timeoutMs = 5000): Promise<void> {
    return flushQueue(serverChanQueue, timeoutMs)
}