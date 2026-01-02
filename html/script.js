const root = document.getElementById("insurance-root");
const vehicleList = document.getElementById("vehicle-list");
const claimsList = document.getElementById("claims-list");
const statInsured = document.getElementById("stat-insured");
const statTotal = document.getElementById("stat-total");
const statInterval = document.getElementById("stat-interval");
const btnClose = document.getElementById("btn-close");

const coverageModal = document.getElementById("coverage-modal");
const coverageOptions = document.getElementById("coverage-options");
const coverageModalPlate = document.getElementById("coverage-modal-plate");
const coverageModalCancel = document.getElementById("coverage-modal-cancel");

let snapshot = {
  vehicles: [],
  claims: [],
  premiumIntervalMinutes: 10,
  serverTime: 0,
  policyTypes: {},
  claimCooldownMinutes: 30, // minutes, from server
};

let currentCoveragePlate = null;

function formatCurrency(value) {
  value = Number(value) || 0;
  return "$" + value.toLocaleString();
}

function formatNextPayment(nextPaymentAt, serverTime) {
  nextPaymentAt = Number(nextPaymentAt) || 0;
  serverTime = Number(serverTime) || 0;

  if (!nextPaymentAt || !serverTime) return "N/A";

  const diffSec = nextPaymentAt - serverTime;
  if (diffSec <= 0) return "Due now";

  const minutes = Math.round(diffSec / 60);
  if (minutes < 1) return "< 1 min";

  if (minutes < 60) {
    return minutes + " min";
  }

  const hours = (minutes / 60).toFixed(1);
  return hours + " h";
}

function formatClaimCooldown(seconds) {
  seconds = Number(seconds) || 0;
  if (seconds <= 0) return "";

  const minutes = Math.ceil(seconds / 60);
  if (minutes <= 1) return "Claim available in < 1 min";
  return `Claim available in ${minutes} min`;
}

function computeModelName(vehicle) {
  if (!vehicle) return "Vehicle";
  const props = vehicle.props || {};
  if (props.displayName) return props.displayName;
  if (props.modelName) return props.modelName;
  if (typeof vehicle.model === "string") return vehicle.model;
  return "Model " + String(vehicle.model || "?");
}

function getPolicyLabel(policyType) {
  if (!policyType || policyType === "none") return "None";
  const types = snapshot.policyTypes || {};
  const plan = types[policyType];
  return (plan && plan.label) || policyType;
}

function getCoverageBadgeClass(policyType, insured) {
  if (!insured || !policyType || policyType === "none")
    return "coverage-badge-none";
  if (policyType === "basic") return "coverage-badge-basic";
  if (policyType === "full") return "coverage-badge-full";
  return "coverage-badge-standard";
}

function renderStats() {
  const vehicles = snapshot.vehicles || [];
  const insuredCount = vehicles.filter((v) => v.insured).length;
  const parkedCount = vehicles.filter((v) => v.parked).length;

  statInsured.textContent = insuredCount;
  statTotal.textContent = parkedCount;
  statInterval.textContent =
    (snapshot.premiumIntervalMinutes || 10) + " min";
}

/**
 * VEHICLE ROWS – GTA style like your screenshot
 */
function renderVehicles() {
  if (!vehicleList) return;

  const vehicles = (snapshot.vehicles || []).slice().sort((a, b) => {
    const ap = a.parked ? 0 : 1;
    const bp = b.parked ? 0 : 1;
    if (ap !== bp) return ap - bp;
    const pa = (a.plate || "").toUpperCase();
    const pb = (b.plate || "").toUpperCase();
    return pa.localeCompare(pb);
  });

  vehicleList.innerHTML = "";

  if (vehicles.length === 0) {
    const empty = document.createElement("div");
    empty.className = "vehicle-card vehicle-empty";
    empty.innerHTML =
      "<div class='vehicle-left'><div class='vehicle-plate'>No vehicles</div>" +
      "<div class='vehicle-meta'>Park a vehicle using your parking script to insure it.</div></div>";
    vehicleList.appendChild(empty);
    return;
  }

  const premiumInterval = snapshot.premiumIntervalMinutes || 10;

  vehicles.forEach((v) => {
    const card = document.createElement("div");
    card.className = "vehicle-card";
    card.dataset.plate = v.plate;

    const isParked = !!v.parked;
    const insured = !!v.insured;

    // cooldown is in seconds from server
    const cooldownSeconds = Number(v.claimCooldown) || 0;
    const canClaim =
      insured && !isParked && cooldownSeconds <= 0;

    const statusClass = insured ? "badge-insured" : "badge-uninsured";
    const statusText = insured ? "Insured" : "Not insured";

    const parkedLabel = isParked
      ? "Parked vehicle"
      : "Not parked / missing";

    const coverageLabel = getPolicyLabel(v.policyType);
    const coverageClass = getCoverageBadgeClass(v.policyType, insured);

    const cooldownLabel = formatClaimCooldown(cooldownSeconds);
    const nextDueLabel = formatNextPayment(
      v.nextPaymentAt,
      snapshot.serverTime
    );

    let actionsHtml = "";

    if (!insured) {
      // parked but no plan yet – GTA style "buy coverage" bar
      actionsHtml = `
        <button class="btn btn-primary" data-action="coverage" data-plate="${v.plate}">
          Select coverage plan
        </button>
      `;
    } else if (canClaim) {
      // insured + missing + cooldown OK → show claim button
      actionsHtml = `
        <button class="btn btn-danger" data-action="claim" data-plate="${v.plate}">
          File theft claim
        </button>
        <button class="btn btn-ghost" data-action="cancel" data-plate="${v.plate}">
          Cancel policy
        </button>
      `;
    } else if (!isParked) {
      // insured + missing but still on cooldown
      const info =
        cooldownLabel ||
        "Claim recently filed. Please wait before filing again.";
      actionsHtml = `
        <button class="btn btn-ghost" data-action="cancel" data-plate="${v.plate}">
          Cancel policy
        </button>
        <span class="claim-cooldown">${info}</span>
      `;
    } else {
      // insured + currently parked
      actionsHtml = `
        <button class="btn btn-ghost" data-action="cancel" data-plate="${v.plate}">
          Cancel policy
        </button>
        <span class="claim-cooldown">Vehicle is parked – claim available if it goes missing.</span>
      `;
    }

    // GTA-style horizontal row layout
    card.innerHTML = `
      <div class="vehicle-left">
        <div class="vehicle-header">
          <div class="vehicle-plate">${v.plate || "UNKNOWN"}</div>
          <div class="vehicle-model">${computeModelName(v)}</div>
        </div>
        <div class="vehicle-meta">
          <span>${parkedLabel}</span>
          <span class="badge ${statusClass}">${statusText}</span>
        </div>

        <div class="vehicle-plan-row">
          <div class="plan-line-top">
            <span class="plan-label">Plan</span>
            <span class="plan-name ${coverageClass}">${coverageLabel.toUpperCase()}</span>
          </div>
          <div class="plan-line-bottom">
            <span>Premium <strong>${formatCurrency(v.premium)}</strong></span>
            <span>${premiumInterval}m · Deductible <strong>${formatCurrency(v.deductible)}</strong></span>
            <span>Next due <strong>${nextDueLabel}</strong></span>
          </div>
        </div>
      </div>

      <div class="vehicle-actions">
        ${actionsHtml}
      </div>
    `;

    vehicleList.appendChild(card);
  });
}

function renderClaims() {
  if (!claimsList) return;

  const claims = snapshot.claims || [];
  claimsList.innerHTML = "";

  if (!claims.length) {
    const empty = document.createElement("div");
    empty.className = "claims-empty";
    empty.textContent = "No claims filed yet.";
    claimsList.appendChild(empty);
    return;
  }

  claims.forEach((c) => {
    const row = document.createElement("div");
    row.className = "claim-row";

    const ts = Number(c.filed_at) || 0;
    const date = ts ? new Date(ts * 1000) : null;
    const dateStr = date && !isNaN(date.getTime()) ? date.toLocaleString() : "";

    row.innerHTML = `
      <div class="claim-row-top">
        <span class="claim-plate">${c.plate || "UNKNOWN"}</span>
        <span class="claim-status">${(c.status || "APPROVED").toUpperCase()}</span>
      </div>
      <div class="claim-row-meta">
        <span>${(c.policy_type || "standard").toUpperCase()} coverage</span>
        <span>Deductible ${formatCurrency(c.deductible_charged || 0)}</span>
      </div>
      <div class="claim-row-meta">
        <span>${dateStr}</span>
      </div>
    `;

    claimsList.appendChild(row);
  });
}

function render() {
  snapshot.vehicles = snapshot.vehicles || [];
  snapshot.claims = snapshot.claims || [];
  snapshot.policyTypes = snapshot.policyTypes || {};

  renderStats();
  renderVehicles();
  renderClaims();
}

/* NUI helpers */

function postNui(action, data) {
  fetch(`https://${GetParentResourceName()}/${action}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json; charset=UTF-8",
    },
    body: JSON.stringify(data || {}),
  }).catch(() => {});
}

/* Coverage modal */

function openCoverageModal(plate) {
  const types = snapshot.policyTypes || {};
  currentCoveragePlate = plate;
  coverageModalPlate.textContent = plate || "";

  coverageOptions.innerHTML = "";

  const entries = Object.entries(types);
  if (!entries.length) {
    const fallback = [
      { key: "basic", label: "Basic coverage", desc: "Cheapest with high deductible." },
      { key: "standard", label: "Standard coverage", desc: "Balanced plan." },
      { key: "full", label: "Full coverage", desc: "0 deductible theft replacement." },
    ];
    fallback.forEach((p) => {
      const btn = document.createElement("button");
      btn.className = "coverage-option";
      btn.dataset.policyType = p.key;
      btn.innerHTML = `
        <div class="coverage-option-main">
          <div class="coverage-option-label">${p.label}</div>
          <div class="coverage-option-desc">${p.desc}</div>
        </div>
      `;
      coverageOptions.appendChild(btn);
    });
  } else {
    entries.forEach(([key, plan]) => {
      const btn = document.createElement("button");
      btn.className = "coverage-option";
      btn.dataset.policyType = key;
      const mult = plan.premiumMultiplier || 1;
      const multText = Math.round(mult * 100) + "% of base premium";

      btn.innerHTML = `
        <div class="coverage-option-main">
          <div class="coverage-option-label">${plan.label || key}</div>
          <div class="coverage-option-desc">${plan.description || ""}</div>
        </div>
        <div class="coverage-option-meta">${multText}</div>
      `;
      coverageOptions.appendChild(btn);
    });
  }

  coverageModal.classList.remove("hidden");
}

function closeCoverageModal() {
  coverageModal.classList.add("hidden");
  currentCoveragePlate = null;
}

/* Events */

btnClose.addEventListener("click", () => {
  postNui("insurance_close", {});
});

vehicleList.addEventListener("click", (e) => {
  const targetCoverage = e.target.closest("[data-action='coverage']");
  if (targetCoverage) {
    const plate = targetCoverage.dataset.plate;
    if (plate) openCoverageModal(plate);
    return;
  }

  const btn = e.target.closest("button[data-action]");
  if (!btn) return;

  const action = btn.dataset.action;
  const plate = btn.dataset.plate;
  if (!action || !plate) return;

  if (action === "coverage") {
    openCoverageModal(plate);
  } else if (action === "cancel") {
    postNui("insurance_cancel", { plate });
  } else if (action === "claim") {
    postNui("insurance_claim", { plate });
  }
});

coverageOptions.addEventListener("click", (e) => {
  const btn = e.target.closest(".coverage-option");
  if (!btn || !currentCoveragePlate) return;

  const policyType = btn.dataset.policyType || "standard";

  postNui("insurance_start", {
    plate: currentCoveragePlate,
    policyType,
  });

  closeCoverageModal();
});

coverageModalCancel.addEventListener("click", () => {
  closeCoverageModal();
});

window.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    if (!coverageModal.classList.contains("hidden")) {
      closeCoverageModal();
    } else {
      postNui("insurance_close", {});
    }
  }
});

/* Messages from client.lua */

window.addEventListener("message", (event) => {
  const data = event.data;
  if (!data || !data.action) return;

  if (data.action === "openInsurance") {
    snapshot = data.snapshot || snapshot;
    if (!snapshot.premiumIntervalMinutes) snapshot.premiumIntervalMinutes = 10;
    root.classList.remove("hidden");
    render();
  } else if (data.action === "closeInsurance") {
    root.classList.add("hidden");
  }
});
