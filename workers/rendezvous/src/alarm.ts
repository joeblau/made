/** The subset of Durable Object storage that alarm scheduling touches. */
export type AlarmStorage = Pick<
  DurableObjectStorage,
  "getAlarm" | "setAlarm" | "deleteAlarm"
>;

/**
 * Keeps a Durable Object alarm no later than the earliest required deadline,
 * writing storage only when the schedule must move earlier, be created, or be
 * cleared.
 *
 * An alarm that fires before the required deadline is harmless: the handler
 * recomputes deadlines from persisted state and calls `replace`. So when
 * activity only pushes deadlines later, the existing alarm is reused.
 *
 * The scheduled time is cached in memory, but the cache starts unknown on every
 * new (or hibernation-reconstructed) instance and is then read back from
 * storage, so decisions never depend on state that does not survive eviction.
 *
 * If `alarm()` throws before `replace`, the cache keeps the fired (now past)
 * time, so `require` skips writes until the handler runs again. That is safe:
 * the runtime retries a failed alarm, and the retry rewrites the schedule.
 */
export class AlarmSchedule {
  #scheduled: number | null | undefined;

  constructor(private readonly storage: AlarmStorage) {}

  /**
   * Ensures an alarm fires at or before `deadline`, or clears the alarm when
   * `deadline` is null.
   */
  async require(deadline: number | null): Promise<void> {
    const scheduled =
      this.#scheduled === undefined
        ? await this.storage.getAlarm()
        : this.#scheduled;

    if (deadline === null) {
      if (scheduled !== null) await this.storage.deleteAlarm();
      this.#scheduled = null;
      return;
    }
    if (scheduled !== null && scheduled <= deadline) {
      this.#scheduled = scheduled;
      return;
    }
    await this.storage.setAlarm(deadline);
    this.#scheduled = deadline;
  }

  /**
   * Unconditionally writes the schedule. Used from `alarm()`, where the alarm
   * that is running must not be mistaken for a pending earlier one.
   */
  async replace(deadline: number | null): Promise<void> {
    if (deadline === null) {
      await this.storage.deleteAlarm();
    } else {
      await this.storage.setAlarm(deadline);
    }
    this.#scheduled = deadline;
  }
}
