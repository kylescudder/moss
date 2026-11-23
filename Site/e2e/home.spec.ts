// Moss-only journeys; the shared ones are in site.spec.ts.
import { test, expect } from '@playwright/test'

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
    await expect(page.locator('.legal > h2').first()).toBeVisible()
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
