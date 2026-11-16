import { test, expect } from '@playwright/test'

test('visitors can read privacy and support information and return home', async ({
  page
}) => {
  await page.goto('/')
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible()
  await page.locator('a[href="/privacy"]').first().click()
  await expect(page).toHaveURL(/\/privacy\/?$/)
  await expect(page.getByRole('heading', { level: 1 })).toContainText(
    /privacy/i
  )
  await expect(page.locator('main')).toContainText(/information|data/i)
  await page.locator('a[href="/support"]').first().click()
  await expect(page).toHaveURL(/\/support\/?$/)
  await expect(page.getByRole('heading', { level: 1 })).toContainText(
    /support/i
  )
  await expect(
    page.locator('main a[href^="mailto:"], main a[href*="github.com"]').first()
  ).toBeVisible()
  await page.locator('a[href="/"]').first().click()
  await expect(page).toHaveURL(/\/$/)
  await page.evaluate(() => document.fonts.ready)
  await page.evaluate(() =>
    Promise.all(
      document
        .getAnimations()
        .filter((a) => a.effect?.getComputedTiming().iterations !== Infinity)
        .map((a) => a.finished)
    )
  )
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth
    )
  ).toBe(true)
})

test('an unknown page returns a real not-found response', async ({ page }) => {
  const response = await page.goto('/e2e-page-that-does-not-exist')
  expect(response?.status()).toBe(404)
  await expect(page.locator('body')).toContainText(/404|not found/i)
})
