
import firebase_admin
from firebase_admin import credentials, firestore
import math

# Initialize Firebase Admin
cred = credentials.ApplicationDefault()
firebase_admin.initialize_app(cred)
db = firestore.client()

def adp_to_value(adp, A=10000, B=0.3):
    return A / (adp ** B)

def effective_value(values):
    weights = [1.0, 0.8, 0.6, 0.4, 0.2]  # diminishing returns
    return sum(val * weights[i] if i < len(weights) else val * 0.1 for i, val in enumerate(values))

def generate_trade_suggestions(user_team, other_teams, players_data, max_value_diff=400, prioritize_equal_count=False):
    suggestions = []

    for opponent_team in other_teams:
        for give_player in user_team:
            for get_player in opponent_team:
                if give_player == get_player:
                    continue

                give = players_data.get(give_player)
                get = players_data.get(get_player)
                if not give or not get:
                    continue

                give_value = adp_to_value(give['adp'])
                get_value = adp_to_value(get['adp'])

                value_diff = get_value - give_value
                if value_diff > max_value_diff:
                    continue

                if prioritize_equal_count:
                    # Both sides must have 1 player (1-for-1 trades only)
                    if isinstance(give_player, list) and len(give_player) != 1:
                        continue
                    if isinstance(get_player, list) and len(get_player) != 1:
                        continue

                suggestions.append({
                    "you_give": give_player,
                    "you_get": get_player,
                    "value_you_give": give_value,
                    "value_you_get": get_value,
                    "value_diff": value_diff,
                    "match_team_id": opponent_team["teamId"]
                })

    return suggestions

def on_user_trade_settings_updated(event, context):
    user_id = event["value"]["fields"]["userId"]["stringValue"]
    league_id = event["value"]["fields"]["leagueId"]["stringValue"]

    # Fetch user team
    team_ref = db.collection("leagues").document(league_id).collection("teams")
    teams = list(team_ref.stream())
    user_team_doc = [t for t in teams if t.get("userId") == user_id][0]
    user_team = user_team_doc.get("roster")

    # Fetch other teams' rosters
    other_teams = [t.get("roster") for t in teams if t.get("userId") != user_id]

    # Fetch all players
    players = {doc.id: doc.to_dict() for doc in db.collection("players").stream()}

    # Get user settings
    settings_doc = db.collection("settings").document(f"{user_id}_{league_id}").get()
    settings = settings_doc.to_dict() if settings_doc.exists else {}
    max_value_diff = settings.get("maxValueDiff", 400)
    prioritize_equal_count = settings.get("prioritizeEqualPlayerCount", True)

    # Generate suggestions
    trades = generate_trade_suggestions(user_team, other_teams, players, max_value_diff, prioritize_equal_count)

    # Save suggestions to Firestore
    suggestions_ref = db.collection("leagues").document(league_id).collection("suggestedTrades")
    for trade in trades:
        suggestions_ref.add(trade)
