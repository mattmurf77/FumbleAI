
import { db, auth } from './firebase-auth.js';
import {
  setDoc, doc, getDoc
} from 'https://www.gstatic.com/firebasejs/10.12.0/firebase-firestore.js';

export async function export async function saveStrategy(userId, leagueId, strategy, targets, giving, prioritize, block) {
  const strategyDoc = doc(db, "userLeagueStrategies", userId + "_" + leagueId);
  await setDoc(strategyDoc, {
    userId,
    leagueId,
    strategy,
    targets,
    giving,
    prioritize,
    block
  });
} {
  const strategyDoc = doc(db, "userLeagueStrategies", userId + "_" + leagueId);
  await setDoc(strategyDoc, {
    userId,
    leagueId,
    strategy,
    targets
  });
}

export async function getStrategy(userId, leagueId) {
  const strategyDoc = doc(db, "userLeagueStrategies", userId + "_" + leagueId);
  const snap = await getDoc(strategyDoc);
  if (snap.exists()) return snap.data();
  return null;
}
