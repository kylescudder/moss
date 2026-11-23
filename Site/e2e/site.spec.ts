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

test('visitors can follow the example trip, see how Moss works and find the App Store download', async ({
  page
}) => {
  await page.goto('/')
  await expect(
    page.getByRole('heading', { level: 1, name: /in the order it happens/i })
  ).toBeVisible()
  const route = page.getByRole('figure', { name: /example day/i })
  await expect(route.getByRole('listitem')).toHaveCount(6)
  await expect(route.getByText('Next', { exact: true })).toBeVisible()

  await page
    .getByRole('navigation', { name: 'Site' })
    .getByRole('link', { name: 'How it works' })
    .click()
  await expect(page).toHaveURL(/#how$/)
  for (const name of [
    'Before you go',
    'On the day',
    'Back home',
    'Get Moss',
    'Further down the line'
  ]) {
    await expect(page.getByRole('heading', { level: 2, name })).toBeVisible()
  }

  const access = page.getByRole('link', { name: 'Download on the App Store' })
  await expect(access).toHaveCount(2)
  for (const link of await access.all()) {
    await expect(link).toHaveAttribute(
      'href',
      /^https:\/\/apps\.apple\.com\/app\//
    )
  }

  await page.screenshot({
    path: test.info().outputPath('home.png'),
    fullPage: true
  })
  await page.goto('/')
  await page.keyboard.press('Tab')
  await expect(
    page.getByRole('link', { name: 'Skip to content' })
  ).toBeFocused()

  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth
    )
  ).toBe(true)
})

test('legal pages read as a route of sections', async ({ page }) => {
  for (const path of ['/support', '/privacy', '/terms']) {
    await page.goto(path)
    await expect(page.locator('.document-body h2').first()).toBeVisible()
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth
      )
    ).toBe(true)
    await page.screenshot({
      path: test.info().outputPath(`${path.slice(1)}.png`),
      fullPage: true
    })
  }
  await page.goto('/no-such-page')
  await expect(page.getByRole('heading', { level: 1 })).toHaveText(
    'Page not found'
  )
  await page.screenshot({
    path: test.info().outputPath('not-found.png'),
    fullPage: true
  })
})
