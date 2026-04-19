(function attachCrossQcTime(root, factory) {
  const api = factory();
  root.CrossQcTime = api;
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, () => {
  const RELATIVE_UNITS = [
    { unit: "year", ms: 365 * 24 * 60 * 60 * 1000 },
    { unit: "month", ms: 30 * 24 * 60 * 60 * 1000 },
    { unit: "week", ms: 7 * 24 * 60 * 60 * 1000 },
    { unit: "day", ms: 24 * 60 * 60 * 1000 },
    { unit: "hour", ms: 60 * 60 * 1000 },
    { unit: "minute", ms: 60 * 1000 },
    { unit: "second", ms: 1000 }
  ];

  let absoluteFormatter = null;
  let relativeFormatter = null;

  function getAbsoluteFormatter() {
    if (!absoluteFormatter) {
      absoluteFormatter = new Intl.DateTimeFormat(undefined, {
        dateStyle: "medium",
        timeStyle: "medium"
      });
    }
    return absoluteFormatter;
  }

  function getRelativeFormatter() {
    if (!relativeFormatter) {
      relativeFormatter = new Intl.RelativeTimeFormat(undefined, {
        style: "short",
        numeric: "always"
      });
    }
    return relativeFormatter;
  }

  function parseTimestamp(value) {
    const raw = String(value || "").trim();
    if (!raw) {
      return { raw: "", date: null };
    }

    const date = new Date(raw);
    if (Number.isNaN(date.getTime())) {
      return { raw, date: null };
    }

    return { raw, date };
  }

  function formatAbsoluteTimestamp(value) {
    const parsed = parseTimestamp(value);
    if (!parsed.raw) {
      return "unknown";
    }
    if (!parsed.date) {
      return parsed.raw;
    }
    return getAbsoluteFormatter().format(parsed.date);
  }

  function chooseRelativeUnit(absDiffMs) {
    return RELATIVE_UNITS.find((entry) => absDiffMs >= entry.ms) || RELATIVE_UNITS[RELATIVE_UNITS.length - 1];
  }

  function formatRelativeTimestamp(value, options = {}) {
    const parsed = parseTimestamp(value);
    if (!parsed.raw) {
      return "unknown";
    }
    if (!parsed.date) {
      return parsed.raw;
    }

    const now = Number.isFinite(options.now) ? options.now : Date.now();
    const diffMs = parsed.date.getTime() - now;
    const absDiffMs = Math.abs(diffMs);
    const { unit, ms } = chooseRelativeUnit(absDiffMs);
    const direction = diffMs < 0 ? -1 : 1;
    const magnitude = Math.max(1, Math.floor(absDiffMs / ms));
    return getRelativeFormatter().format(direction * magnitude, unit);
  }

  function formatEventTimestamp(value, options = {}) {
    const parsed = parseTimestamp(value);
    if (!parsed.raw) {
      return {
        label: "unknown",
        title: ""
      };
    }

    if (!parsed.date) {
      return {
        label: parsed.raw,
        title: parsed.raw
      };
    }

    return {
      label: formatRelativeTimestamp(parsed.raw, options),
      title: formatAbsoluteTimestamp(parsed.raw)
    };
  }

  return {
    formatAbsoluteTimestamp,
    formatEventTimestamp,
    formatRelativeTimestamp,
    parseTimestamp
  };
});
