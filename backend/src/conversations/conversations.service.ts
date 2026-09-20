import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { Conversation } from './conversation.entity';
import { User } from '../users/user.entity';
import { Message } from '../messages/message.entity';

@Injectable()
export class ConversationsService {
  constructor(
    @InjectRepository(Conversation)
    private convRepo: Repository<Conversation>,
    @InjectRepository(Message)
    private messageRepo: Repository<Message>,
  ) {}

  // Find an existing conversation between two users.
  // If none exists — create a new one. This prevents duplicates.
  async findOrCreate(userOne: User, userTwo: User): Promise<Conversation> {
    const existing = await this.convRepo.findOne({
      where: [
        { userOne: { id: userOne.id }, userTwo: { id: userTwo.id } },
        { userOne: { id: userTwo.id }, userTwo: { id: userOne.id } },
      ],
    });
    if (existing) return existing;

    try {
      const conv = this.convRepo.create({ userOne, userTwo });
      return await this.convRepo.save(conv);
    } catch (err) {
      // A unique violation (Postgres 23505) from UQ_conversations_user_pair means
      // a concurrent request inserted the same pair first — re-read and return the
      // winning row. Any other error is a real failure and must propagate.
      const code =
        (err as { code?: string; driverError?: { code?: string } })?.code ??
        (err as { driverError?: { code?: string } })?.driverError?.code;
      if (code !== '23505') throw err;
      const race = await this.convRepo.findOne({
        where: [
          { userOne: { id: userOne.id }, userTwo: { id: userTwo.id } },
          { userOne: { id: userTwo.id }, userTwo: { id: userOne.id } },
        ],
      });
      if (race) return race;
      throw new Error(`Failed to find or create conversation`);
    }
  }

  async findById(id: number): Promise<Conversation | null> {
    return this.convRepo.findOne({
      where: { id },
      relations: {
        userOne: { profilePhotos: true },
        userTwo: { profilePhotos: true },
      },
    });
  }

  // All conversations for a given user
  async findByUser(userId: number): Promise<Conversation[]> {
    return this.convRepo.find({
      where: [{ userOne: { id: userId } }, { userTwo: { id: userId } }],
      relations: {
        userOne: { profilePhotos: true },
        userTwo: { profilePhotos: true },
      },
    });
  }

  // Find conversation between two specific users
  async findByUsers(
    userId1: number,
    userId2: number,
  ): Promise<Conversation | null> {
    return this.convRepo.findOne({
      where: [
        { userOne: { id: userId1 }, userTwo: { id: userId2 } },
        { userOne: { id: userId2 }, userTwo: { id: userId1 } },
      ],
    });
  }

  async delete(id: number): Promise<void> {
    // Delete messages first (no cascade configured)
    await this.messageRepo.delete({ conversation: { id } });
    await this.convRepo.delete({ id });
  }

  async updateDisappearingTimer(
    conversationId: number,
    seconds: number | null,
  ): Promise<Conversation | null> {
    const conversation = await this.findById(conversationId);
    if (!conversation) return null;

    conversation.disappearingTimer = seconds;
    return this.convRepo.save(conversation);
  }

  async setPinnedMessage(
    conversationId: number,
    messageId: number,
    userId: number,
  ): Promise<Conversation> {
    const conv = await this.findById(conversationId);
    if (!conv) throw new Error('Conversation not found');
    const userBelongs =
      conv.userOne.id === userId || conv.userTwo.id === userId;
    if (!userBelongs) throw new Error('Unauthorized');
    const message = await this.messageRepo.findOne({
      where: { id: messageId },
      relations: {
        conversation: true,
      },
    });
    if (!message || message.conversation.id !== conversationId) {
      throw new Error('Message not in conversation');
    }
    conv.pinnedMessageId = messageId;
    conv.pinnedAt = new Date();
    conv.pinnedByUserId = userId;
    return this.convRepo.save(conv);
  }

  async clearPinnedMessage(conversationId: number): Promise<void> {
    await this.convRepo.update(conversationId, {
      pinnedMessageId: null,
      pinnedAt: null,
      pinnedByUserId: null,
    });
  }
}
