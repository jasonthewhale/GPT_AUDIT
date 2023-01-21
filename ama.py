import numpy as np
from numpy.linalg import norm
import subprocess
import textwrap
import dotenv
import openai
import json
import time
import os
import re

dotenv.load_dotenv(".env")

# set APIKEY
openai.api_key = os.getenv("API_KEY")

def slither_scan(contract_path):
    result = subprocess.run(['slither', contract_path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return result


def get_folder_files(folder_path):
    input_files = []
    for (dirpath, dirnames, filenames) in os.walk(folder_path):
        input_files += [os.path.join(dirpath, file) for file in filenames]
    return input_files


def get_sol_files(folder_path):
    all_files = get_folder_files(folder_path)
    sol_files_list = [f for f in all_files if f.endswith('.sol')]
    return sol_files_list


def get_reports():
    sol_files = get_sol_files('solidity_folder')
    report_list = []
    for sol_file in sol_files:
        report = slither_scan(sol_file)
        report_list.append(report)
    print('\n'.join(report_list))


def get_contract_name(folder_path):
    name_list =[]
    input_files = get_folder_files(folder_path)
    for file in input_files:
        name = file[len(folder_path)+1 : -4]
        name_list.append(name)
    return name_list


def merge_contract(folder_path, merge_file):
    input_files = get_folder_files(folder_path)
    with open(merge_file, 'a') as outfile:
        for file in input_files:
            content = open_file(file)
            outfile.write(content)
        outfile.close()


def open_file(filename):
    with open(filename, 'r') as file:
        return file.read()


def append_file(filename, input):
    with open(filename, 'a') as file:
        file.write(input)


def load_json(filepath):
    with open(filepath, 'r', encoding='utf-8') as infile:
        return json.load(infile)


def save_json(filepath, payload):
    with open(filepath, 'w', encoding='utf-8') as outfile:
        json.dump(payload, outfile, ensure_ascii=False, sort_keys=True, indent=2)


def words_counter(filename):
    count = 0
    with open(filename, 'r') as file:
        for line in file:
            count += len(line)
    return count


def merge_logs(log_list):
    merged_log_text = []
    for i in log_list:
        merged_log_text.append(i['content'])
    return '\n'.join(merged_log_text)


def gpt3_embedding(content, engine='text-similarity-ada-001'):
    content = content.encode(encoding='ASCII', errors="ignore").decode()
    response = openai.Embedding.create(input=content,engine=engine)
    vector = response['data'][0]['embedding'] 
    return vector


def save_embedding(text_path, index_path):
    chunks = ''
    all_text = open_file(text_path)
    if text_path == 'chatlog.txt':
        chunks = textwrap.wrap(all_text, 500) # set chatlog chunks to 500 words
    else:
        chunks = textwrap.wrap(all_text, 3600) # set contract info chunks to 3600 words
    result = []
    for chunk in chunks:
        embedding = gpt3_embedding(chunk.encode(encoding='ASCII',errors='ignore').decode())
        info = {'content': chunk, 'vector': embedding}
        result.append(info)
        time.sleep(5) # OpenAI ratelimit is 1 request per second
    save_json(index_path, result)


def similarity(vector1, vector2):
    return np.dot(vector1,vector2)/(norm(vector1)*norm(vector2))


def fetch_info(text, info_path, count):
    scores = []
    vector = gpt3_embedding(text)
    info = load_json(info_path)
    for i in info:
        if info_path == 'chatlog.json' and vector == i['vector']:
            continue
        score = similarity(i['vector'], vector)
        i['score'] = score
        scores.append(i)
    rank = sorted(scores, key=lambda d: d['score'], reverse=True)
    top_similarity = rank[0:count]
    return top_similarity


def ask_gpt(prompt):
    response = openai.Completion.create(
        model="text-davinci-003",
        prompt=prompt,
        temperature=0.7,
        max_tokens=512,
        top_p=1,
        frequency_penalty=0,
        presence_penalty=0
    )
    reply = response["choices"][0]["text"].strip()
    return reply


def main():
    # use slither to create a static analyze report
    get_reports()
    conversation = []
    # ask GPT about general thoughts of user's project (only appear onece, exclude from chatlog)
    pre_prompt = open_file("pre_prompt_0.txt")
    pre_prompt = pre_prompt + '\nAVI:'
    pre_response = ask_gpt(pre_prompt)
    print(f"AVI: {pre_response}")
    ask_gpt(pre_prompt)
    while True:
        user_input = input("USER: ")
        if user_input == "quit":
            open("chatlog.txt", "w").close()
            break
        else:
            # append user input
            conversation.append(f"USER: {user_input}")
            text_block = '\n' + '\n'.join(conversation)
            # convert chatlog.txt to embedding
            # TODO - append embedding instead of converting whole txt file every prompt
            save_embedding('chatlog.txt', 'chatlog.json')
            append_file("chatlog.txt", text_block)
            conversation = []
            top_contract_mem = fetch_info(user_input, 'index.json', 1)
            contract_info = top_contract_mem[0]['content']
            top_chat_log = fetch_info(user_input, 'chatlog.json', 3)
            chat_log = merge_logs(top_chat_log)
            print(f'\n\ntop_chat-list is: {top_chat_log}\n\n')
            # prompt = previous chat log + related contract info + user question
            prompt = open_file('pre_prompt_1.txt') + '\nCHAT HISTORY:' + chat_log + '\nHINT:' + contract_info + '\nUSER:' + user_input
            print(prompt)
            prompt = prompt + '\nAVI:'
            response = ask_gpt(prompt)
            print(f"AVI: {response}")
            # append gpt response
            conversation.append(f"AVI: {response}")


if __name__ == "__main__":
    main()
