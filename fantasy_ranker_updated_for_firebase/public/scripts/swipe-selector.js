
import { db, auth } from './firebase-auth.js';
import { collection, getDocs, doc, setDoc, updateDoc, query, where } from 'https://www.gstatic.com/firebasejs/10.12.0/firebase-firestore.js';

export async function getNextPlayerPair(scoringFormat = "PPR") {
  const user = auth.currentUser;
  if (!user) throw new Error("User not authenticated");

  const rankingsRef = collection(db, "rankings");
  const q = query(rankingsRef,
    where("userId", "==", user.uid),
    where("scoringFormat", "==", scoringFormat));

  const snapshot = await getDocs(q);
  const players = snapshot.docs.map(doc => ({ ...doc.data(), docId: doc.id }));

  const matchupRef = doc(db, "matchups", user.uid);
  let history = {};
  try {
    const histSnap = await getDocs(collection(db, "matchups/" + user.uid + "/history"));
    histSnap.forEach(doc => {
      const key = doc.id;
      history[key] = true;
    });
  } catch (err) {
    console.warn("No matchup history found");
  }

  let bestPair = null;
  let minDiff = Infinity;

  for (let i = 0; i < players.length; i++) {
    for (let j = i + 1; j < players.length; j++) {
      const p1 = players[i], p2 = players[j];
      const key = [p1.playerId, p2.playerId].sort().join("_");
      if (history[key]) continue;

      const diff = Math.abs((p1.elo || 1000) - (p2.elo || 1000));
      if (diff < minDiff) {
        minDiff = diff;
        bestPair = { p1, p2, key };
      }
    }
  }

  if (!bestPair) return null;

  // Store this matchup to prevent repeat
  await setDoc(doc(db, "matchups/" + user.uid + "/history", bestPair.key), {
    shownAt: new Date().toISOString()
  });

  return [bestPair.p1, bestPair.p2];
}
