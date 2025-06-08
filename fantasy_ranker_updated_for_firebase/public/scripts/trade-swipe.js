
import { logTradeFeedback } from './trade-feedback.js';

async function handleTradeAction(actionType) {
  const user = auth.currentUser;
  if (!user) return;

  const leagueId = localStorage.getItem('currentLeagueId');
  const trade = currentTrades[currentIndex];

  await logTradeFeedback(user.uid, leagueId, trade, actionType);
}

import { db, auth } from './firebase-auth.js';
import {
  doc, getDocs, setDoc, collection, query, where
} from 'https://www.gstatic.com/firebasejs/10.12.0/firebase-firestore.js';

let currentTrades = [];
let currentIndex = 0;

// Load trade suggestions
import { getStrategy } from './strategy-storage.js';

// Modified loadTradeSuggestions to filter based on user preferences
async function loadTradeSuggestions() {
  const user = auth.currentUser;
  if (!user) return;

  const leagueId = localStorage.getItem('currentLeagueId');
  const userId = user.uid;

  const strategyData = await getStrategy(userId, leagueId);
  if (!strategyData) return;

  const { strategy, targets, giving, prioritize, block } = strategyData;

  const allSuggestionsSnap = await getDocs(
    query(collection(db, "tradeSuggestions"), where("leagueId", "==", leagueId))
  );

  const incomingInterestSnap = await getDocs(
    query(collection(db, "savedTrades"), where("targetTeamOwner", "==", userId))
  );

  const interestMap = new Map();
  incomingInterestSnap.forEach(doc => {
    const d = doc.data();
    const key = d.fromPlayer + "->" + d.toPlayer;
    interestMap.set(key, true);
  });

  const prioritized = [];
  const regular = [];

  allSuggestionsSnap.forEach(doc => {
    const data = doc.data();
    const key = data.fromPlayer + "->" + data.toPlayer;

    const toPos = data.toPlayerPosition || "";
    const fromPos = data.fromPlayerPosition || "";
    const toName = data.toPlayerName || "";
    const fromName = data.fromPlayerName || "";

    const isBlocked = block.some(b => toName.includes(b) || fromName.includes(b));
    const matchesTargets = targets.includes(toPos);
    const matchesGiving = giving.includes(fromPos);
    const isPrioritized = prioritize.some(p => fromName.includes(p));

    if (isBlocked || !matchesTargets || !matchesGiving) return;

    const suggestion = { id: doc.id, ...data };

    if (interestMap.has(key)) {
      prioritized.unshift(suggestion);
    } else if (isPrioritized) {
      prioritized.push(suggestion);
    } else {
      regular.push(suggestion);
    }
  });

  currentTrades = [...prioritized, ...regular];
  currentIndex = 0;

  showNextTrade();
}

// Show the next trade
function showNextTrade() {
  const trade = currentTrades[currentIndex];
  const container = document.getElementById("tradeDetails");

  if (!trade) {
    container.innerHTML = "<p>No more trade suggestions.</p>";
    return;
  }

  container.innerHTML = `
    <div class="player-block"><span><strong>You Give:</strong></span><span>${trade.fromPlayer}</span></div>
    <div class="player-block"><span><strong>You Get:</strong></span><span>${trade.toPlayer}</span></div>
    <p class="text-muted mt-2">Suggested trade with ${trade.targetTeamOwner}</p>
  `;

  const matchBanner = document.getElementById("matchBanner");
  matchBanner.style.display = "none";
}

// Swipe Left - reject
document.getElementById("rejectBtn").addEventListener("click", async () => {
    await handleTradeAction("rejected");
    currentIndex++;
    showNextTrade();
  }); => {
  currentIndex++;
  showNextTrade();
});

// Swipe Right - save
document.getElementById("saveBtn").addEventListener("click", async () => {
    await handleTradeAction("approved");
    saveCurrentTrade(); // existing save logic
    currentIndex++;
    showNextTrade();
  }); => {
  const user = auth.currentUser;
  const trade = currentTrades[currentIndex];
  if (!user || !trade) return;

  const savedKey = user.uid + "_" + trade.id;
  await setDoc(doc(db, "savedTrades", savedKey), {
    userId: user.uid,
    leagueId: trade.leagueId,
    fromPlayer: trade.fromPlayer,
    toPlayer: trade.toPlayer,
    targetTeamOwner: trade.targetTeamOwner,
    savedAt: new Date().toISOString()
  });

  // Check if the other user saved this already (MATCH!)
  const reverseMatch = await getDocs(query(
    collection(db, "savedTrades"),
    where("userId", "==", trade.targetTeamOwner),
    where("fromPlayer", "==", trade.toPlayer),
    where("toPlayer", "==", trade.fromPlayer)
  ));

  if (!reverseMatch.empty) {
    const matchBanner = document.getElementById("matchBanner");
    matchBanner.style.display = "block";
  }

  currentIndex++;
  setTimeout(showNextTrade, 500);
});

auth.onAuthStateChanged(user => {
  if (user) {
    loadTradeSuggestions();
  }
});



import { saveStrategy, getStrategy } from './strategy-storage.js';

document.getElementById("leagueSelect").addEventListener("change", async function() {
  const leagueId = this.value;
  if (!leagueId) return;
  localStorage.setItem('currentLeagueId', leagueId);

  const user = auth.currentUser;
  if (!user) return;

  const strategyData = await getStrategy(user.uid, leagueId);
  if (!strategyData) {
    document.getElementById("strategySetup").style.display = "block";
  } else {
    document.getElementById("strategySetup").style.display = "none";
    loadTradeSuggestions();
  }
});

document.getElementById("saveStrategyBtn").addEventListener("click", async function() {
  const strategy = document.getElementById("teamStrategy").value;
  const targets = [];
  ["QB", "RB", "WR", "TE"].forEach(pos => {
    if (document.getElementById("pos" + pos).checked) targets.push(pos);
  });

  const leagueId = document.getElementById("leagueSelect").value;
  const user = auth.currentUser;
  if (!strategy || targets.length === 0 || !leagueId || !user) return;

  const giving = [];
  ["QB", "RB", "WR", "TE"].forEach(pos => {
    if (document.getElementById("give" + pos).checked) giving.push(pos);
  });

  const prioritize = document.getElementById("prioritizePlayers").value.split(",").map(s => s.trim()).filter(Boolean);
  const block = document.getElementById("blockPlayers").value.split(",").map(s => s.trim()).filter(Boolean);

  await saveStrategy(user.uid, leagueId, strategy, targets, giving, prioritize, block);

  document.getElementById("strategySetup").style.display = "none";
  loadTradeSuggestions();
});
