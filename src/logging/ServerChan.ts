import axios, { AxiosRequestConfig } from 'axios'
import PQueue from 'p-queue'
import type { WebhookServerChanConfig } from '../interface/Config'

const serverChanQueue = new PQueue({
    interval: 1000,
    intervalCap: 2,
    carryoverConcurrencyCount: true
})

export async function sendServerChan(config: WebhookServerChanConfig, content: string): Promise<void> {
    if (!config?.sendkey) return

    const request: AxiosRequestConfig = {
        method: 'POST',
        url: `https://sctapi.ftqq.com/${config.sendkey}.send`,
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        data: new URLSearchParams({
            title: (config.title ?? 'Microsoft Rewards 通知').slice(0, 32),
            desp: content,
            ...(config.short ? { short: config.short.slice(0, 64) } : {})
        }).toString(),
        timeout: 10000
    }

    await serverChanQueue.add(async () => {
        try {
            await axios(request)
        } catch (err: any) {
            const status = err?.response?.status
            if (status === 429) return
        }
    })
}

export async function flushServerChanQueue(timeoutMs = 5000): Promise<void> {
    await Promise.race([
        (async () => {
            await serverChanQueue.onIdle()
        })(),
        new Promise<void>((_, reject) => setTimeout(() => reject(new Error('Server酱刷新超时')), timeoutMs))
    ]).catch(() => { })
}
