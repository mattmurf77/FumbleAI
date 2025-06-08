
import { db, auth } from './firebase-auth.js';
import {
  doc, updateDoc, getDocs, collection, query, where, setDoc
} from 'https://www.gstatic.com/firebasejs/10.12.0/firebase-firestore.js';

const BASE_ELO = 1500;
const K_FACTOR = 32;

// Elo calculation
function updateElo(winner, loser) {
  const expectedWin = 1 / (1 + Math.pow(10, (loser.elo - winner.elo) / 400));
  const expectedLose = 1 / (1 + Math.pow(10, (winner.elo - loser.elo) / 400));
  winner.elo += K_FACTOR * (1 - expectedWin);
  loser.elo += K_FACTOR * (0 - expectedLose);
}

// Tiers based on Elo clusters
function calculateTiers(players) {
  const sorted = [...players].sort((a, b) => b.elo - a.elo);
  const tiers = [];
  let currentTier = [];
  let previousElo = sorted[0]?.elo || BASE_ELO;

  for (let i = 0; i < sorted.length; i++) {
    const player = sorted[i];
    if (
      currentTier.length > 0 &&
      Math.abs(player.elo - previousElo) > 75
    ) {
      tiers.push(currentTier);
      currentTier = [];
    }
    currentTier.push(player);
    previousElo = player.elo;
  }

  if (currentTier.length > 0) tiers.push(currentTier);
  return tiers;
}

// Confidence = score distance to next player
function calculateConfidenceBars(players) {
  const sorted = [...players].sort((a, b) => b.elo - a.elo);
  return sorted.map((player, i) => {
    const diffBefore = i > 0 ? Math.abs(player.elo - sorted[i - 1].elo) : 0;
    const diffAfter = i < sorted.length - 1 ? Math.abs(player.elo - sorted[i + 1].elo) : 0;
    const confidence = Math.max(diffBefore, diffAfter);
    return { ...player, confidence };
  });
}

// Submit a swipe and update Firestore
async function submitSwipe(winnerId, loserId, scoringFormat) {
  const uid = auth.currentUser?.uid;
  if (!uid) throw new Error("User not authenticated");

  const q = query(collection(db, 'rankings'),
    where('userId', '==', uid),
    where('scoringFormat', '==', scoringFormat));
  const snap = await getDocs(q);

  const rankings = [];
  snap.forEach(doc => rankings.push({ ...doc.data(), docId: doc.id }));

  const winner = rankings.find(p => p.playerId === winnerId);
  const loser = rankings.find(p => p.playerId === loserId);
  if (!winner || !loser) throw new Error("Players not found");

  updateElo(winner, loser);

  // Update Firestore docs
  await Promise.all([
    updateDoc(doc(db, 'rankings', winner.docId), { elo: winner.elo }),
    updateDoc(doc(db, 'rankings', loser.docId), { elo: loser.elo })
  ]);

  const updated = rankings.map(p =>
    p.playerId === winnerId ? winner :
    p.playerId === loserId ? loser : p);

  const tiers = calculateTiers(updated);
  const withConfidence = calculateConfidenceBars(updated);

  return {
    updatedRankings: withConfidence,
    tiers
  };
}

// Manual reranking within a tier
export async function rerankTier(tierPlayers, newOrder, scoringFormat) {
  const uid = auth.currentUser?.uid;
  if (!uid) throw new Error("User not authenticated");

  const tierSize = tierPlayers.length;
  const updates = [];

  for (let i = 0; i < newOrder.length; i++) {
    const playerId = newOrder[i];
    const playerDoc = tierPlayers.find(p => p.playerId === playerId);
    if (playerDoc) {
      const newElo = BASE_ELO + (tierSize - i) * 20; // Space 20 pts apart
      updates.push(setDoc(doc(db, 'rankings', playerDoc.docId), {
        ...playerDoc,
        elo: newElo
      }));
    }
  }

  await Promise.all(updates);
}
