
import {
  collection, addDoc, serverTimestamp
} from 'https://www.gstatic.com/firebasejs/10.12.0/firebase-firestore.js';

// Log trade interaction to Firestore
async function logTradeFeedback(userId, leagueId, tradeData, action) {
  try {
    await addDoc(collection(db, "tradeFeedback"), {
      userId,
      leagueId,
      action, // "approved" or "rejected"
      fromPlayer: tradeData.fromPlayer,
      fromPlayerId: tradeData.fromPlayerId,
      toPlayer: tradeData.toPlayer,
      toPlayerId: tradeData.toPlayerId,
      fromPlayerPosition: tradeData.fromPlayerPosition,
      toPlayerPosition: tradeData.toPlayerPosition,
      timestamp: serverTimestamp()
    });
  } catch (e) {
    console.error("Failed to log trade feedback:", e);
  }
}
