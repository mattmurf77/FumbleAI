
// Constants for Elo system
const BASE_ELO = 1500;
const K_FACTOR = 32;

// Called when a user swipes to choose winner over loser
function updateElo(winner, loser) {
  const expectedWin =
    1 / (1 + Math.pow(10, (loser.elo - winner.elo) / 400));
  const expectedLose = 1 / (1 + Math.pow(10, (winner.elo - loser.elo) / 400));

  winner.elo += K_FACTOR * (1 - expectedWin);
  loser.elo += K_FACTOR * (0 - expectedLose);
}

// Given a list of players with Elo scores, assign them into tiers
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
