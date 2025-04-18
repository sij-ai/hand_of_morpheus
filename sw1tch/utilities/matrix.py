import asyncio
import time
import re
from typing import List, Dict, Union, Optional
from fastapi import HTTPException
from nio import AsyncClient, RoomMessageText, RoomMessageNotice

from sw1tch import config, logger

def parse_response(response_text: str, query: str) -> Dict[str, Union[str, List[str]]]:
    query_parts = query.strip().split()
    array_key = query_parts[0] if query_parts else "data"
    codeblock_pattern = r"(.*?):\s*\n```\s*\n([\s\S]*?)\n```"
    match = re.search(codeblock_pattern, response_text)
    if match:
        message = match.group(1).strip()
        items = [line for line in match.group(2).split('\n') if line.strip()]
        return {"message": message, array_key: items}
    return {"response": response_text}

async def get_matrix_users() -> List[str]:
    matrix_config = config["matrix_admin"]
    homeserver = config["base_url"]
    username = matrix_config.get("username")
    password = matrix_config.get("password")
    admin_room = matrix_config.get("room")
    admin_response_user = matrix_config.get("super_admin")
    if not all([homeserver, username, password, admin_room, admin_response_user]):
        raise HTTPException(status_code=500, detail="Incomplete Matrix admin configuration")
    client = AsyncClient(homeserver, username)
    try:
        login_response = await client.login(password)
        if getattr(login_response, "error", None):
            raise Exception(f"Login error: {login_response.error}")
        logger.debug("Successfully logged in to Matrix")
        await client.join(admin_room)
        initial_sync = await client.sync(timeout=5000)
        next_batch = initial_sync.next_batch
        await client.room_send(
            room_id=admin_room,
            message_type="m.room.message",
            content={"msgtype": "m.text", "body": "!admin users list-users"},
        )
        query_time = time.time()
        timeout_seconds = 10
        start_time = time.time()
        response_message = None
        while (time.time() - start_time) < timeout_seconds:
            sync_response = await client.sync(timeout=2000, since=next_batch)
            next_batch = sync_response.next_batch
            room = sync_response.rooms.join.get(admin_room)
            if room and room.timeline and room.timeline.events:
                message_events = [e for e in room.timeline.events if isinstance(e, (RoomMessageText, RoomMessageNotice))]
                for event in message_events:
                    event_time = event.server_timestamp / 1000.0
                    if event.sender == admin_response_user and event_time >= query_time:
                        response_message = event.body
                        logger.debug(f"Found response: {response_message[:100]}...")
                        break
                if response_message:
                    break
        await client.logout()
        await client.close()
        if not response_message:
            raise HTTPException(status_code=504, detail="No response from admin user within timeout")
        parsed = parse_response(response_message, "users list-users")
        return parsed.get("users", [])
    except Exception as e:
        await client.close()
        logger.error(f"Error fetching Matrix users: {e}")
        raise HTTPException(status_code=500, detail=f"Error fetching users: {e}")

async def deactivate_user(user: str) -> bool:
    matrix_config = config["matrix_admin"]
    homeserver = config["base_url"]
    username = matrix_config.get("username")
    password = matrix_config.get("password")
    admin_room = matrix_config.get("room")
    client = AsyncClient(homeserver, username)
    try:
        login_response = await client.login(password)
        if getattr(login_response, "error", None):
            raise Exception(f"Login error: {login_response.error}")
        logger.debug(f"Logged in to deactivate {user}")
        await client.join(admin_room)
        await client.sync(timeout=5000)
        command = f"!admin users deactivate {user}"
        await client.room_send(
            room_id=admin_room,
            message_type="m.room.message",
            content={"msgtype": "m.text", "body": command},
        )
        logger.info(f"Sent deactivation command for {user}")
        await asyncio.sleep(1)
        await client.logout()
        await client.close()
        return True
    except Exception as e:
        await client.close()
        logger.error(f"Failed to deactivate {user}: {e}")
        return False

async def get_matrix_rooms(page: int) -> List[Dict[str, Union[str, int]]]:
    matrix_config = config["matrix_admin"]
    homeserver = config["base_url"]
    username = matrix_config.get("username")
    password = matrix_config.get("password")
    admin_room = matrix_config.get("room")
    admin_response_user = matrix_config.get("super_admin")
    if not all([homeserver, username, password, admin_room, admin_response_user]):
        raise HTTPException(status_code=500, detail="Incomplete Matrix admin configuration")
    client = AsyncClient(homeserver, username)
    try:
        login_response = await client.login(password)
        if getattr(login_response, "error", None):
            raise Exception(f"Login error: {login_response.error}")
        logger.debug(f"Fetching rooms for page {page}")
        await client.join(admin_room)
        initial_sync = await client.sync(timeout=5000)
        next_batch = initial_sync.next_batch
        command = f"!admin rooms list-rooms {page} --exclude-banned --exclude-disabled"
        await client.room_send(
            room_id=admin_room,
            message_type="m.room.message",
            content={"msgtype": "m.text", "body": command},
        )
        query_time = time.time()
        timeout_seconds = 10
        start_time = time.time()
        response_message = None
        while (time.time() - start_time) < timeout_seconds:
            sync_response = await client.sync(timeout=2000, since=next_batch)
            next_batch = sync_response.next_batch
            room = sync_response.rooms.join.get(admin_room)
            if room and room.timeline and room.timeline.events:
                message_events = [e for e in room.timeline.events if isinstance(e, (RoomMessageText, RoomMessageNotice))]
                for event in message_events:
                    event_time = event.server_timestamp / 1000.0
                    if event.sender == admin_response_user and event_time >= query_time:
                        response_message = event.body
                        logger.debug(f"Found rooms response: {response_message[:100]}...")
                        break
                if response_message:
                    break
        await client.logout()
        await client.close()
        if not response_message:
            raise HTTPException(status_code=504, detail="No response from admin user within timeout")
        
        # Parse the response
        parsed = parse_response(response_message, "rooms list-rooms")
        room_pattern = r"(!\S+)\s+Members: (\d+)\s+Name: (.*)"
        rooms = []
        for line in parsed.get("rooms", []):
            match = re.match(room_pattern, line)
            if match:
                room_id, members, name = match.groups()
                rooms.append({
                    "room_id": room_id,
                    "members": int(members),
                    "name": name.strip()
                })
        return rooms
    except Exception as e:
        await client.close()
        logger.error(f"Error fetching rooms for page {page}: {e}")
        raise HTTPException(status_code=500, detail=f"Error fetching rooms: {e}")

async def get_room_members(room_id: str, local_only: bool = False) -> Dict[str, Union[str, int, List[Dict[str, str]]]]:
    matrix_config = config["matrix_admin"]
    homeserver = config["base_url"]
    username = matrix_config.get("username")
    password = matrix_config.get("password")
    admin_room = matrix_config.get("room")
    admin_response_user = matrix_config.get("super_admin")
    if not all([homeserver, username, password, admin_room, admin_response_user]):
        raise HTTPException(status_code=500, detail="Incomplete Matrix admin configuration")
    client = AsyncClient(homeserver, username)
    try:
        login_response = await client.login(password)
        if getattr(login_response, "error", None):
            raise Exception(f"Login error: {login_response.error}")
        logger.debug(f"Fetching members for room {room_id}")
        await client.join(admin_room)
        initial_sync = await client.sync(timeout=5000)
        next_batch = initial_sync.next_batch
        command = f"!admin rooms info list-joined-members {room_id}"
        if local_only:
            command += " --local-only"
        await client.room_send(
            room_id=admin_room,
            message_type="m.room.message",
            content={"msgtype": "m.text", "body": command},
        )
        query_time = time.time()
        timeout_seconds = 10
        start_time = time.time()
        response_message = None
        while (time.time() - start_time) < timeout_seconds:
            sync_response = await client.sync(timeout=2000, since=next_batch)
            next_batch = sync_response.next_batch
            room = sync_response.rooms.join.get(admin_room)
            if room and room.timeline and room.timeline.events:
                message_events = [e for e in room.timeline.events if isinstance(e, (RoomMessageText, RoomMessageNotice))]
                for event in message_events:
                    event_time = event.server_timestamp / 1000.0
                    if event.sender == admin_response_user and event_time >= query_time:
                        response_message = event.body
                        logger.debug(f"Found members response: {response_message[:100]}...")
                        break
                if response_message:
                    break
        await client.logout()
        await client.close()
        if not response_message:
            raise HTTPException(status_code=504, detail="No response from admin user within timeout")
        
        # Parse the response
        parsed = parse_response(response_message, "members list-joined-members")
        member_pattern = r"(@\S+)\s*\|\s*(\S+)"
        members = []
        message_match = re.match(r"(\d+) Members in Room \"(.*)\":", parsed["message"])
        total_members = int(message_match.group(1)) if message_match else 0
        room_name = message_match.group(2) if message_match else room_id
        for line in parsed.get("members", []):
            match = re.match(member_pattern, line)
            if match:
                user_id, display_name = match.groups()
                members.append({"user_id": user_id, "display_name": display_name})
        return {
            "room_id": room_id,
            "room_name": room_name,
            "total_members": total_members,
            "local_members": members
        }
    except Exception as e:
        await client.close()
        logger.error(f"Error fetching members for room {room_id}: {e}")
        raise HTTPException(status_code=500, detail=f"Error fetching room members: {e}")

def check_banned_room_name(room_name: str) -> bool:
    """Check if a room name matches any regex pattern in config/room-ban-regex.txt."""
    try:
        with open("sw1tch/config/room-ban-regex.txt", "r") as f:
            patterns = [line.strip() for line in f if line.strip() and not line.startswith("#")]
        for pattern in patterns:
            if re.search(pattern, room_name, re.IGNORECASE):
                logger.debug(f"Room name '{room_name}' matches banned pattern '{pattern}'")
                return True
        return False
    except FileNotFoundError:
        logger.warning("room-ban-regex.txt not found; no rooms will be considered banned")
        return False
    except Exception as e:
        logger.error(f"Error reading room-ban-regex.txt: {e}")
        return False
