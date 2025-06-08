
import { db, auth } from './firebase-auth.js';
import { collection, query, where, getDocs } from 'https://www.gstatic.com/firebasejs/10.12.0/firebase-firestore.js';

async function loadSavedTrades() {
  const user = auth.currentUser;
  if (!user) return;

  const userId = user.uid;

  const q = query(collection(db, "savedTrades"), where("userId", "==", userId));
  const snapshot = await getDocs(q);

  const saved = [];
  const matches = [];

  const allPartnerSaves = await getDocs(query(
    collection(db, "savedTrades"),
    where("targetTeamOwner", "==", userId)
  ));

  const reverseMatchSet = new Set();
  allPartnerSaves.forEach(doc => {
    const data = doc.data();
    const key = data.toPlayer + "->" + data.fromPlayer;
    reverseMatchSet.add(key);
  });

  snapshot.forEach(doc => {
    const trade = doc.data();
    const key = trade.fromPlayer + "->" + trade.toPlayer;
    if (reverseMatchSet.has(key)) {
      matches.push(trade);
    } else {
      saved.push(trade);
    }
  });

  const matchedContainer = document.getElementById("matchedTradesContainer");
  const regularContainer = document.getElementById("regularTradesContainer");

  if (matches.length === 0) {
    matchedContainer.innerHTML = "<p>No matched trades yet.</p>";
  } else {
    matches.forEach(trade => {
      const card = document.createElement("div");
      card.className = "trade-card border-success";
      card.innerHTML = `
        <div><strong>✅ Matched!</strong></div>
        <div><strong>You Give:</strong> ${trade.fromPlayer}</div>
        <div><strong>You Get:</strong> ${trade.toPlayer}</div>
        <div class="text-muted mt-1">with ${trade.targetTeamOwner}</div>
      `;
      matchedContainer.appendChild(card);
    });
  }

  if (saved.length === 0) {
    regularContainer.innerHTML = "<p>No other saved trades.</p>";
  } else {
    saved.forEach(trade => {
      const card = document.createElement("div");
      card.className = "trade-card";
      card.innerHTML = `
        <div><strong>You Give:</strong> ${trade.fromPlayer}</div>
        <div><strong>You Get:</strong> ${trade.toPlayer}</div>
        <div class="text-muted mt-1">with ${trade.targetTeamOwner}</div>
      `;
      regularContainer.appendChild(card);
    });
  }
}

auth.onAuthStateChanged(user => {
  if (user) {
    loadSavedTrades();
  }
});
