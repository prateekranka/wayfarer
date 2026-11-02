import type { Locator, Screen } from 'e2e';
import { expect } from 'e2e';

/** Native accessibility frames can extend under a pinned footer. Use current frames, never screenshot coordinates. */
export async function revealControl(screen: Screen, target: Locator, direction: 'up' | 'down', footerID: string) {
  for (let attempt = 0; attempt < 18; attempt++) {
    const frame = await target.isVisible() ? await target.boundingBox() : undefined;
    const footer = await screen.getByTestId(footerID).boundingBox();
    const navigation = await screen.getByRole('navigation').first().boundingBox();
    if (frame) {
      const center = frame.y + frame.height / 2;
      const top = navigation ? navigation.y + navigation.height : 0;
      const bottom = footer ? footer.y - 20 : Number.POSITIVE_INFINITY;
      if (center > top + 5 && center < bottom) return;
    }
    // A coordinate path avoids the native driver's expensive scroll-container search.
    // Both endpoints come from the current navigation and footer accessibility frames.
    if (navigation && footer) {
      const top = navigation.y + navigation.height + 12;
      const span = footer.y - 24 - top;
      const x = navigation.x + navigation.width * 0.025;
      const high = top + span * 0.52;
      const low = top + span * 0.62;
      const center = frame ? frame.y + frame.height / 2 : undefined;
      const moveDown = center === undefined ? direction === 'down' : center > footer.y - 20;
      await screen.swipe({ from: { x, y: moveDown ? low : high }, to: { x, y: moveDown ? high : low } });
    } else {
      throw new Error('The scroll surface has no navigation and footer accessibility frames');
    }
  }
  throw new Error('The control remains covered by navigation or the pinned footer');
}

export async function tapControl(screen: Screen, target: Locator, direction: 'up' | 'down', footerID: string) {
  await revealControl(screen, target, direction, footerID);
  await tapVisibleControl(target);
}

/** Use only for a visible control, such as a sheet's Done button. */
export async function tapVisibleControl(target: Locator) {
  await expect(target).toBeVisible({ timeout: 15_000 });
  const frame = await target.boundingBox();
  if (!frame) throw new Error('The revealed control has no accessibility frame');
  // SwiftUI background shapes can trigger the driver's conservative occlusion guard.
  // revealControl has already checked the current center against navigation and the footer.
  await target.tap({ position: { x: frame.width / 2, y: frame.height / 2 } });
}
